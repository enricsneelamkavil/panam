import BackgroundTasks
import Foundation
import GoogleSignIn
import SwiftData

/// Best-effort daily transaction-email fetch scheduled for 10 PM. Background
/// task timing is controlled by iOS, so the same claim is also checked when
/// the app returns to the foreground.
enum AutoEmailFetchScheduler {
    static let taskIdentifier = "enric.Plush.autoEmailFetch"

    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            scheduleNext()
            let work = Task { @MainActor in
                let success = await fetchIfDue(container: container)
                refreshTask.setTaskCompleted(success: success)
            }
            refreshTask.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleNext() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        guard UserDefaults.standard.object(forKey: AppSettings.autoEmailFetchEnabledKey) as? Bool
            ?? AppSettings.autoEmailFetchEnabledDefault else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = nextTenPM()
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func fetchIfDue(container: ModelContainer) async -> Bool {
        guard claimIfDue() else { return true }
        await restorePreviousGoogleSignInIfNeeded()
        let context = container.mainContext
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let senderTerms = AppSettings.parseSenderTerms(
            UserDefaults.standard.string(forKey: AppSettings.gmailSenderTermsKey)
                ?? AppSettings.gmailSenderTermsDefault
        )
        guard !senderTerms.isEmpty else { return true }
        await EmailFetchCoordinator.shared.fetchTransactionEmails(
            senderTerms: senderTerms, categories: categories, accounts: accounts, transactions: transactions
        )
        return !Task.isCancelled
    }

    @MainActor
    private static func claimIfDue(now: Date = .now) -> Bool {
        guard UserDefaults.standard.object(forKey: AppSettings.autoEmailFetchEnabledKey) as? Bool
            ?? AppSettings.autoEmailFetchEnabledDefault else { return false }
        let calendar = Calendar.current
        guard calendar.component(.hour, from: now) >= AppSettings.autoEmailFetchHour else { return false }
        if let previous = UserDefaults.standard.object(forKey: AppSettings.lastAutoEmailFetchDateKey) as? Date,
           calendar.isDate(previous, inSameDayAs: now) {
            return false
        }
        UserDefaults.standard.set(now, forKey: AppSettings.lastAutoEmailFetchDateKey)
        return true
    }

    private static func nextTenPM() -> Date {
        let calendar = Calendar.current
        let now = Date.now
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = AppSettings.autoEmailFetchHour
        components.minute = 0
        components.second = 0
        let today = calendar.date(from: components) ?? now
        return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    private static func restorePreviousGoogleSignInIfNeeded() async {
        guard GIDSignIn.sharedInstance.currentUser == nil else { return }
        await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { _, _ in continuation.resume() }
        }
    }
}
