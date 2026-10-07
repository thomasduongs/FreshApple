import Foundation
import OSLog
import SideSign

struct RefreshProgress: Sendable {
    var fraction: Double
    var message: String
}

actor RefreshCoordinator {
    static let shared = RefreshCoordinator()
    private let repository = AppRepository.shared
    private let provisioning = ProvisioningManager.shared
    private let device = DeviceConnection.shared
    private var running = false
    private var events: [RefreshEvent] = []
    private let log = Logger(subsystem: "FreshApple", category: "Refresh")
    private var logURL: URL { URL.applicationSupportDirectory.appendingPathComponent("FreshApple/events.json") }

    func history() -> [RefreshEvent] {
        if events.isEmpty, let data = try? Data(contentsOf: logURL), let saved = try? JSONDecoder().decode([RefreshEvent].self, from: data) { events = saved }
        return events
    }
    private func record(_ message: String) {
        _ = history()
        events.insert(RefreshEvent(message: message), at: 0)
        events = Array(events.prefix(50))
        log.info("\(message, privacy: .public)")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(events).write(to: logURL, options: .atomic)
    }
    func recordAutomation(_ message: String) { record(message) }

    func importIPA(_ url: URL) async throws {
        guard !running else { throw RefreshError.alreadyRunning }
        running = true
        defer { running = false }
        try await repository.importIPA(url)
    }
    func reconcileSelfInstall() async throws {
        guard !running else { return }
        running = true
        defer { running = false }
        var apps = try await repository.apps()
        guard let index = apps.firstIndex(where: { $0.isSelf && $0.pendingExpiration != nil }) else { return }
        let profileURL = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        if let actual = try? ProvisioningProfile(fileURL: profileURL),
           actual.bundleIdentifier == apps[index].id,
           apps[index].confirmPendingRefresh(installedProfileID: actual.uuid) {
            record("FreshApple’s self-refresh was verified on launch.")
            await BackgroundRefresh.didRefresh()
        } else { record("Self-refresh could not be verified. Refresh again to retry.") }
        apps[index].pendingExpiration = nil
        apps[index].pendingProfileID = nil
        try await repository.save(apps)
        await ExpirationNotifications.schedule(apps)
    }
    func refresh(progress: @escaping @Sendable (RefreshProgress) async -> Void = { _ in }) async throws {
        guard !running else { throw RefreshError.alreadyRunning }
        running = true
        defer { running = false }
        do {
            guard !(try await repository.apps()).isEmpty else { throw RefreshError.noApps }
            record("Refresh started.")
            await progress(.init(fraction: 0.02, message: "Connecting to this iPhone…"))
            let udid = try await device.connect()
            if let address = UserDefaults.standard.string(forKey: "manifestURL"), !address.isEmpty {
                guard let url = URL(string: address) else { throw RefreshError.message("The manifest URL is invalid.") }
                await progress(.init(fraction: 0.05, message: "Checking for new builds…"))
                try await repository.checkManifest(url)
            }
            let apps = try await repository.apps().sorted { lhs, rhs in
                if lhs.isSelf != rhs.isSelf { return !lhs.isSelf }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            for (index, var app) in apps.enumerated() {
                try Task.checkCancellation()
                let base = Double(index) / Double(apps.count)
                await progress(.init(fraction: base, message: "Preparing \(app.displayName)…"))
                let source = try await repository.source(for: app)
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("FreshApple-signing-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: work) }
                let appURL = try AppRepository.extract(source, to: work)
                await progress(.init(fraction: base + 0.25 / Double(apps.count), message: "Signing \(app.displayName) · \(index + 1) of \(apps.count)"))
                let expiry = try await provisioning.sign(appURL: appURL, udid: udid)
                try Task.checkCancellation()
                await progress(.init(fraction: base + 0.75 / Double(apps.count), message: "Installing \(app.displayName)…"))
                try await device.stage(appURL: appURL, bundleID: app.id)
                if app.isSelf {
                    let profile = try ProvisioningProfile(fileURL: appURL.appendingPathComponent("embedded.mobileprovision"))
                    app.pendingProfileID = profile.uuid
                    app.pendingExpiration = expiry
                    try await repository.update(app)
                    await BackgroundRefresh.prepareRetry()
                    record("Other apps are saved. FreshApple self-install is pending verification on next launch.")
                    // The complete signed bundle is on the device's AFC staging area now.
                    try FileManager.default.removeItem(at: work)
                }
                try await device.install(bundleID: app.id, appName: appURL.lastPathComponent)
                if !app.isSelf {
                    app.expirationDate = expiry
                    app.lastRefresh = .now
                    try await repository.update(app)
                    await ExpirationNotifications.schedule(try await repository.apps())
                    record("Refreshed \(app.displayName).")
                }
            }
            await BackgroundRefresh.didRefresh()
            record("Refresh installation requests completed.")
            await progress(.init(fraction: 1, message: apps.contains(where: \.isSelf) ? "Apps refreshed · reopen to verify FreshApple" : "All apps refreshed"))
        } catch {
            // Do not persist arbitrary upstream errors, which can contain account data.
            let reason: String
            switch error {
            case is CancellationError: reason = "Refresh cancelled or background time expired."
            case RefreshError.vpnUnavailable: reason = "Refresh stopped: LocalDevVPN connection was unavailable."
            case RefreshError.pairingRequired: reason = "Refresh stopped: pairing record is required."
            case RefreshError.authenticationRequired: reason = "Refresh stopped: Apple Account sign-in is required."
            case RefreshError.teamRequired: reason = "Refresh stopped: developer team is required."
            case RefreshError.noApps: reason = "Refresh stopped: no source IPAs have been imported."
            default: reason = "Refresh stopped. Open the app and try Refresh Apps for details."
            }
            record(reason)
            throw error
        }
    }
}
