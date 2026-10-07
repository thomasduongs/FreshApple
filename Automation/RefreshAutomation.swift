import AppIntents
import BackgroundTasks
import UserNotifications

struct RefreshAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Apps"
    static var description = IntentDescription("Renew and reinstall your managed apps. Connect LocalDevVPN first.")
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await RefreshCoordinator.shared.refresh()
        return .result(dialog: "Refresh finished. Open FreshApple to view your apps.")
    }
}
struct FreshAppleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RefreshAppsIntent(), phrases: ["Refresh apps with \(.applicationName)"],
                    shortTitle: "Refresh Apps", systemImageName: "arrow.clockwise")
    }
}

enum ExpirationNotifications {
    static func request() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    static func schedule(_ apps: [ManagedApp]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("expiry.") }.map(\.identifier))
        for app in apps {
            guard let expiration = app.expirationDate, expiration > .now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Keep \(app.displayName) fresh"
            content.body = "Your provisioning profile expires soon. Connect LocalDevVPN and refresh your apps."
            content.sound = .default
            let delay = max(60, expiration.addingTimeInterval(-48 * 3600).timeIntervalSinceNow)
            try? await center.add(UNNotificationRequest(identifier: "expiry.\(app.id)", content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
        }
    }
}

private actor BackgroundRefreshScheduler {
    private let key = "backgroundRefreshPlan"

    func schedule(result: Bool? = nil) async {
        let apps = result == nil ? try? await AppRepository.shared.apps() : nil
        var plan = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(BackgroundRefreshPlan.self, from: $0) }
            ?? BackgroundRefreshPlan()
        if let result { plan.completed(success: result) }
        if let apps {
            plan.consider(expirations: apps.compactMap(\.expirationDate))
        }
        // Save retry state even when iOS rejects the request.
        guard let data = try? JSONEncoder().encode(plan) else { return }
        UserDefaults.standard.set(data, forKey: key)
        let request = BGProcessingTaskRequest(identifier: BackgroundRefresh.identifier)
        request.requiresNetworkConnectivity = true
        // Reopening the app must not move an existing request further into the future.
        request.earliestBeginDate = plan.nextAttempt
        do {
            try BGTaskScheduler.shared.submit(request)
            await RefreshCoordinator.shared.recordAutomation("Background refresh requested for \(plan.nextAttempt.formatted()). iOS chooses the actual run time.")
        } catch {
            let code = (error as NSError).code
            await RefreshCoordinator.shared.recordAutomation("Background refresh could not be scheduled (code \(code)). Check Background App Refresh in iOS Settings; use the Refresh Apps Shortcut for a scheduled attempt.")
        }
    }
}

enum BackgroundRefresh {
    static let identifier = "thomasduong.FreshApple.refresh"
    private static let scheduler = BackgroundRefreshScheduler()

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task {
                await RefreshCoordinator.shared.recordAutomation("iOS started background refresh.")
                // Self-installation may terminate us before the handler returns.
                await scheduler.schedule(result: false)
                do {
                    try await RefreshCoordinator.shared.refresh()
                    task.setTaskCompleted(success: true)
                } catch {
                    await scheduler.schedule(result: false)
                    task.setTaskCompleted(success: false)
                }
            }
            task.expirationHandler = { work.cancel() }
        }
    }
    static func schedule() {
        Task { await scheduler.schedule() }
    }
    static func prepareRetry() async {
        await scheduler.schedule(result: false)
    }
    static func catchUpIsDue(at date: Date = .now) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "backgroundRefreshPlan"),
              let plan = try? JSONDecoder().decode(BackgroundRefreshPlan.self, from: data) else { return false }
        return plan.nextAttempt <= date
    }
    static func didRefresh() async {
        await scheduler.schedule(result: true)
    }
}
