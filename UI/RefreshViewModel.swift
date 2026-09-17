import SwiftUI
import SideSign

@MainActor
final class RefreshViewModel: ObservableObject {
    @Published var apps: [ManagedApp] = []
    @Published var busy = false
    @Published var progress = RefreshProgress(fraction: 0, message: "Ready when you are")
    @Published var error: String?
    @Published var success = false
    @Published var events: [RefreshEvent] = []
    @Published var teams: [Team] = []
    @Published var selectedTeam: Team?
    @Published var certificateExpiry: Date?
    @Published var paired = false
    @Published var connectionStatus = "Not checked"
    @Published var authenticating = false
    @Published var verificationRequest: TwoFactorRequest?
    private var verificationContinuation: CheckedContinuation<TwoFactorResponse, Error>?
    private var operation: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?

    var earliestExpiry: Date? { apps.compactMap(\.expirationDate).min() }
    var lastRefresh: Date? { apps.compactMap(\.lastRefresh).min() }
    var daysRemaining: Int? {
        guard !apps.isEmpty, apps.allSatisfy({ $0.expirationDate != nil }), let earliestExpiry else { return nil }
        return max(0, Int(ceil(earliestExpiry.timeIntervalSinceNow / 86400)))
    }
    func load() async {
        do {
            try await RefreshCoordinator.shared.reconcileSelfInstall()
            apps = try await AppRepository.shared.apps()
            selectedTeam = try await ProvisioningManager.shared.selectedTeam()
            certificateExpiry = try await ProvisioningManager.shared.certificateExpiration()
            paired = PairingStore().isConfigured
            events = await RefreshCoordinator.shared.history()
        } catch { self.error = error.localizedDescription }
    }
    private func setProgress(_ state: RefreshProgress) { progress = state }
    func refresh() {
        guard !busy else { return }
        busy = true; success = false; error = nil
        operation = Task {
            defer { busy = false }
            do {
                try await RefreshCoordinator.shared.refresh { [weak self] state in
                    await self?.setProgress(state)
                }
                success = true
            } catch is CancellationError { progress.message = "Refresh cancelled" }
            catch { self.error = error.localizedDescription }
            await load()
        }
    }
    func importIPA(_ result: Result<URL, Error>) {
        guard !busy else { return }
        busy = true; error = nil; success = false
        progress = .init(fraction: 0, message: "Importing source IPA…")
        operation = Task {
            defer { busy = false }
            do { try await RefreshCoordinator.shared.importIPA(result.get()); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
    func importPairing(_ result: Result<URL, Error>) {
        do { try PairingStore().importRecord(from: result.get()); paired = true; connectionStatus = "Not checked" }
        catch { self.error = error.localizedDescription }
    }
    func testConnection() async {
        connectionStatus = "Checking…"
        do { _ = try await DeviceConnection.shared.connect(); connectionStatus = "Connected to this iPhone" }
        catch { connectionStatus = error.localizedDescription }
    }
    func signIn(email: String, password: String, server: String) {
        guard !authenticating else { return }
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { error = "Enter an HTTPS anisette URL."; return }
        authenticating = true; error = nil
        signInTask = Task {
            defer { authenticating = false }
            do {
                teams = try await ProvisioningManager.shared.signIn(email: email, password: password, server: url) { [weak self] request in
                    guard let self else { return .cancel }
                    return try await self.requestVerification(request)
                }
                if teams.count == 1, let team = teams.first { try await ProvisioningManager.shared.select(team) }
                await load()
            } catch is CancellationError {
                // Dismissing Setup or cancelling sign-in is not an authentication failure.
            } catch { self.error = error.localizedDescription }
        }
    }
    func requestVerification(_ request: TwoFactorRequest) async throws -> TwoFactorResponse {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                verificationRequest = request
                verificationContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.verify(.cancel) }
        }
    }
    func verify(_ response: TwoFactorResponse) {
        verificationRequest = nil
        verificationContinuation?.resume(returning: response)
        verificationContinuation = nil
    }
    func cancelSignIn() {
        verify(.cancel)
        signInTask?.cancel()
    }
    func selectTeam(_ id: String) async {
        guard let team = teams.first(where: { $0.id == id }) else { return }
        do { try await ProvisioningManager.shared.select(team); await load() }
        catch { self.error = error.localizedDescription }
    }
    func loadTeams() async {
        do { teams = try await ProvisioningManager.shared.teams() }
        catch { self.error = error.localizedDescription }
    }
}
