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

enum BackgroundRefresh {
    static let identifier = "thomasduong.FreshApple.refresh"
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task {
                defer { schedule() }
                do { try await RefreshCoordinator.shared.refresh(); task.setTaskCompleted(success: true) }
                catch { task.setTaskCompleted(success: false) }
            }
            task.expirationHandler = { work.cancel() }
        }
    }
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(3 * 86400)
        try? BGTaskScheduler.shared.submit(request)
    }
}
