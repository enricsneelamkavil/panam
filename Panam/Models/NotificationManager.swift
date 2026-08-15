//
//  NotificationManager.swift
//  Panam
//

import Foundation
import UserNotifications

/// Owns every local notification Panam schedules: the one-off "your fetch
/// finished" alert (see EmailFetchCoordinator's runTransactionFetch/
/// runStatementFetch) and the optional recurring 10 PM "log today's
/// transactions" nudge (see SettingsView's Daily Reminder toggle).
///
/// A class (not an enum of static funcs, unlike most of this app's other
/// singletons) because UNUserNotificationCenterDelegate requires
/// NSObjectProtocol conformance — the delegate has to be a real object
/// UNUserNotificationCenter can hold a reference to, not just a namespace.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Stable identifier for the recurring reminder request — reused on
    /// every (re)schedule so toggling the time or re-enabling the setting
    /// replaces the previous request instead of stacking duplicates.
    private static let dailyReminderIdentifier = "enric.Plush.dailyReminder"

    private override init() { super.init() }

    // MARK: - Authorization

    /// Prompts for notification permission if — and only if — the user has
    /// never been asked before. Safe to call from multiple entry points
    /// (Settings' Daily Reminder toggle, the first Fetch Emails tap) since
    /// checking authorizationStatus first means every call after the first
    /// is a harmless no-op rather than a repeat prompt (iOS wouldn't show a
    /// second system prompt anyway, but this also skips the async round
    /// trip once the user has already decided either way).
    func requestAuthorizationIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Fetch-completion notification

    /// Fires once a Transaction Mails / Statement Mails fetch finishes —
    /// unconditionally on success (including a 0-found result), since this
    /// is the only confirmation the user gets that a fetch which may have
    /// continued in the background actually completed. `kind` is
    /// "Transaction" or "Statement", matching which sheet's Fetch Emails
    /// button started it.
    func notifyFetchComplete(kind: String, newCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(kind) fetch complete"
        content.body = newCount == 0
            ? "No new transactions found."
            : "\(newCount) new transaction\(newCount == 1 ? "" : "s") found."
        content.sound = .default

        // nil trigger = deliver as soon as possible, same as any other
        // "something just finished" notification — there's no future time
        // to wait for.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Daily reminder

    /// (Re)schedules the recurring reminder for `hour:minute` every day,
    /// replacing whatever was scheduled before under the same identifier.
    /// UNCalendarNotificationTrigger with repeats: true is a standing
    /// request iOS owns from here on — unlike BGTaskScheduler, there's
    /// nothing to re-submit on every app launch; it fires on its own until
    /// cancelDailyReminder() removes it or the app is deleted.
    func scheduleDailyReminder(hour: Int, minute: Int) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.dailyReminderIdentifier])

        let content = UNMutableNotificationContent()
        content.title = "Panam"
        content.body = "Don't forget to log today's transactions."
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(identifier: Self.dailyReminderIdentifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelDailyReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.dailyReminderIdentifier])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Without a delegate, iOS silently drops a local notification's
    /// banner/sound whenever it fires while the app is already in the
    /// foreground — fine for most apps, but wrong here: "fetch complete"
    /// firing while you're sitting in Transaction Mails watching it finish
    /// is exactly when you'd still want the banner, and the 10 PM reminder
    /// should show up even if Panam happens to be open at 10 PM. Returning
    /// .banner/.sound here makes foreground delivery behave the same as
    /// backgrounded delivery.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
