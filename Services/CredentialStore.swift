import Foundation
import Security

struct CredentialStore: Sendable {
    private let service = "FreshApple.credentials"
    func read(_ name: String) throws -> Data? {
        var query = base(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        return result as? Data
    }
    func write(_ data: Data, for name: String) throws {
        let query = base(name)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let result = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard result == errSecSuccess else { throw failure(result) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    func remove(_ name: String) throws {
        let result = SecItemDelete(base(name) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw failure(result) }
    }
    private func base(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: name, kSecAttrSynchronizable as String: false]
    }
    private func failure(_ status: OSStatus) -> Error {
        if status == errSecMissingEntitlement {
            return RefreshError.message("This build is missing its Keychain signing entitlement. Run a signed build from Xcode.")
        }
        return RefreshError.message("Secure storage is unavailable (\(status)). Unlock your iPhone and try again.")
    }
}

struct PairingStore {
    private let credentials = CredentialStore()
    var isConfigured: Bool { (try? credentials.read("pairing")) != nil }
    func load() throws -> String {
        guard let data = try credentials.read("pairing"), let value = String(data: data, encoding: .utf8) else {
            throw RefreshError.pairingRequired
        }
        return value
    }
    func importRecord(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count < 2_000_000,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["HostID"] is String, plist["SystemBUID"] is String,
              plist["HostPrivateKey"] is Data, plist["HostCertificate"] is Data else {
            throw RefreshError.message("Choose a valid lockdown pairing record (.mobiledevicepairing or .plist) from your Mac.")
        }
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try credentials.write(xml, for: "pairing")
    }
}
