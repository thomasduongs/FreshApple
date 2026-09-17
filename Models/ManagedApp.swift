import Foundation

struct ManagedApp: Codable, Identifiable, Sendable, Equatable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    var displayName: String
    var version: String
    var sourceFile: String
    var sha256: String
    var lastRefresh: Date?
    var expirationDate: Date?
    var pendingExpiration: Date?
    var sourceURL: URL?
    var pendingProfileID: UUID?

    mutating func confirmPendingRefresh(installedProfileID: UUID, at date: Date = .now) -> Bool {
        guard let expected = pendingProfileID, installedProfileID == expected,
              let expiration = pendingExpiration else { return false }
        expirationDate = expiration
        lastRefresh = date
        pendingExpiration = nil
        pendingProfileID = nil
        return true
    }

    var isSelf: Bool { bundleIdentifier == Bundle.main.bundleIdentifier }
    func daysRemaining(at date: Date = .now) -> Int? {
        expirationDate.map { max(0, Int(ceil($0.timeIntervalSince(date) / 86400))) }
    }
}

struct BuildManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let bundleID: String
        let version: String
        let ipa: URL
        let sha256: String
    }
    let apps: [Entry]
}

enum RefreshError: LocalizedError {
    case message(String)
    case pairingRequired, vpnUnavailable, authenticationRequired, teamRequired
    case noApps, alreadyRunning, invalidIPA, certificateUnavailable
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .pairingRequired: "Import this iPhone’s pairing record in Setup."
        case .vpnUnavailable: "Cannot reach this iPhone. Connect LocalDevVPN and try again."
        case .authenticationRequired: "Sign in to your Apple Account in Setup. Your session may have expired."
        case .teamRequired: "Choose your developer team in Setup."
        case .noApps: "Add an IPA to start managing your apps."
        case .alreadyRunning: "A refresh is already in progress."
        case .invalidIPA: "This file is not a valid, supported IPA."
        case .certificateUnavailable: "Your signing certificate is unavailable or expired. Open Setup to prepare a certificate."
        }
    }
}

struct RefreshEvent: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    let message: String
}
