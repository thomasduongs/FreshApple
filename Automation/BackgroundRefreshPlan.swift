import Foundation

struct BackgroundRefreshPlan: Codable, Sendable {
    var nextAttempt: Date
    var lastAttempt: Date?

    init(now: Date = .now) { nextAttempt = now.addingTimeInterval(3 * 86400) }

    mutating func completed(success: Bool, at date: Date = .now) {
        lastAttempt = date
        nextAttempt = date.addingTimeInterval(success ? 3 * 86400 : 6 * 3600)
    }
    mutating func consider(expirations: [Date], at date: Date = .now) {
        guard let earliest = expirations.min() else { return }
        // Leave 48 hours to recover from a missed or failed background launch.
        let deadline = earliest.addingTimeInterval(-48 * 3600)
        let retryFloor = lastAttempt?.addingTimeInterval(6 * 3600) ?? date
        nextAttempt = min(nextAttempt, max(deadline, retryFloor, date))
    }
}

