import Foundation
import CryptoKit
import SideSign

actor AppRepository {
    static let shared = AppRepository()
    let root: URL
    private var registryURL: URL { root.appendingPathComponent("registry.json") }
    init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("FreshApple")) { self.root = root }

    func apps() throws -> [ManagedApp] {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return [] }
        return try JSONDecoder().decode([ManagedApp].self, from: Data(contentsOf: registryURL))
    }
    func save(_ apps: [ManagedApp]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(apps).write(to: registryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func update(_ app: ManagedApp) throws {
        var all = try apps()
        if let index = all.firstIndex(where: { $0.id == app.id }) { all[index] = app }
        else { all.append(app) }
        try save(all)
    }
    func source(for app: ManagedApp) throws -> URL {
        guard app.sourceFile == URL(fileURLWithPath: app.sourceFile).lastPathComponent else { throw RefreshError.invalidIPA }
        let url = root.appendingPathComponent("Apps").appendingPathComponent(app.sourceFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RefreshError.message("The source IPA for \(app.displayName) is missing. Import it again.")
        }
        guard try Self.checksum(url) == app.sha256 else {
            throw RefreshError.message("The cached IPA for \(app.displayName) failed its integrity check. Import it again.")
        }
        return url
    }
    @discardableResult
    func importIPA(_ url: URL, expected: BuildManifest.Entry? = nil) throws -> ManagedApp {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = work.appendingPathComponent("source.ipa")
        try FileManager.default.copyItem(at: url, to: staged)
        let hash = try Self.checksum(staged)
        if let expected, hash != expected.sha256.lowercased() {
            throw RefreshError.message("The download failed its SHA-256 integrity check.")
        }
        let appURL = try Self.extract(staged, to: work.appendingPathComponent("unpacked"))
        guard let bundle = AppBundle(fileURL: appURL), !bundle.bundleIdentifier.isEmpty else { throw RefreshError.invalidIPA }
        if let expected, expected.bundleID != bundle.bundleIdentifier || expected.version != bundle.version {
            throw RefreshError.message("The downloaded app does not match its manifest.")
        }
        let old = try apps().first { $0.id == bundle.bundleIdentifier }
        let file = UUID().uuidString + ".ipa"
        let directory = root.appendingPathComponent("Apps")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(file)
        try FileManager.default.moveItem(at: staged, to: destination)
        let app = ManagedApp(bundleIdentifier: bundle.bundleIdentifier, displayName: bundle.name,
                             version: bundle.version, sourceFile: file, sha256: hash,
                             lastRefresh: old?.lastRefresh, expirationDate: old?.expirationDate,
                             pendingExpiration: old?.pendingExpiration, sourceURL: expected?.ipa ?? old?.sourceURL)
        do { try update(app) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        if let old { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.sourceFile)) }
        return app
    }
    func checkManifest(_ url: URL) async throws {
        guard url.scheme == "https" else { throw RefreshError.message("Use an HTTPS manifest URL.") }
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.validate(response)
        let manifest = try JSONDecoder().decode(BuildManifest.self, from: data)
        guard Set(manifest.apps.map(\.bundleID)).count == manifest.apps.count else {
            throw RefreshError.message("The manifest contains duplicate bundle identifiers.")
        }
        for entry in manifest.apps {
            try Task.checkCancellation()
            // Only update apps that the user has explicitly imported.
            guard let cached = try apps().first(where: { $0.id == entry.bundleID }) else { continue }
            guard entry.ipa.scheme == "https", entry.sha256.count == 64,
                  entry.sha256.allSatisfy(\.isHexDigit) else { throw RefreshError.message("Invalid manifest URL or SHA-256 checksum.") }
            if entry.version.compare(cached.version, options: .numeric) == .orderedAscending { continue }
            if entry.version == cached.version && entry.sha256.lowercased() == cached.sha256 { continue }
            let (download, response) = try await URLSession.shared.download(from: entry.ipa)
            defer { try? FileManager.default.removeItem(at: download) }
            try Self.validate(response)
            try importIPA(download, expected: entry)
        }
    }
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme == "https" else { throw RefreshError.message("The build server returned an unsuccessful or insecure response.") }
    }
    static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func extract(_ source: URL, to destination: URL) throws -> URL {
        let archive = try Archive.Reader.open(at: source)
        let entries = try archive.entries()
        var total: Int64 = 0
        var appNames = Set<String>()
        for entry in entries {
            let components = entry.filename.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.filename.hasPrefix("/"), !components.contains(".."),
                  !entry.filename.contains("\\"), entry.uncompressedSize >= 0,
                  entry.uncompressedSize <= 4_000_000_000,
                  (entry.externalAttributes >> 16) & 0o170000 != 0o120000 else { throw RefreshError.invalidIPA }
            total += entry.uncompressedSize
            guard total <= 4_000_000_000 else { throw RefreshError.message("The expanded IPA exceeds 4 GB.") }
            if components.count >= 2, components[0] == "Payload", components[1].hasSuffix(".app") { appNames.insert(String(components[1])) }
        }
        guard appNames.count == 1 else { throw RefreshError.invalidIPA }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return try FileManager.default.unzipAppBundle(at: source, to: destination)
    }
}
