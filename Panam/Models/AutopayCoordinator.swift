//
//  AutopayCoordinator.swift
//  Panam
//

import Foundation

/// Shared "is today's automatic autopay run due, and has one already
/// claimed it" check used by both of autopay's two triggers — PanamApp's
/// .task (cold launch) and its on-scenePhase-active handler. Mirrors
/// AutoBackupCoordinator exactly, for the same reason: two independent
/// triggers exist so both a truly cold process launch and a
/// backgrounded-then-resumed app get a chance to catch autopay up, but
/// only one of them should actually run it on any given day.
///
/// Both call `claimIfDue()` before running AutopayProcessor, never after
/// — whichever asks first writes `lastAutopayRunDateKey` immediately, so
/// if the two happen to fire close together (e.g. scenePhase flips to
/// .active while .task's async chain is still resolving), the second
/// caller sees today already claimed and skips instead of processing
/// autopays twice. This is a plain check-then-set against UserDefaults,
/// not a lock — good enough for two triggers on one device for one user,
/// not built to survive a genuine concurrent race.
enum AutopayCoordinator {
    /// Checks whether the configured hour has passed for today and
    /// nothing has claimed today yet — and if both hold, immediately
    /// marks today claimed and returns true. Returns false (claiming
    /// nothing) the moment either condition fails.
    ///
    /// Unlike AutoBackupCoordinator there's no separate on/off switch
    /// here — autopay itself is always "on" at the coordinator level;
    /// individual RecurringPayment/Investment templates opt in via their
    /// own autopayEnabled flag, checked inside AutopayProcessor.
    static func claimIfDue(now: Date = .now) -> Bool {
        let defaults = UserDefaults.standard

        let hour = defaults.object(forKey: AppSettings.autopayHourKey) as? Int
            ?? AppSettings.autopayHourDefault
        guard Calendar.current.component(.hour, from: now) >= hour else { return false }

        let lastRun = defaults.object(forKey: AppSettings.lastAutopayRunDateKey) as? Date
        if let lastRun, Calendar.current.isDate(lastRun, inSameDayAs: now) {
            return false
        }

        defaults.set(now, forKey: AppSettings.lastAutopayRunDateKey)
        return true
    }
}
