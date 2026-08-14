//
//  AutoBackupCoordinator.swift
//  Panam
//

import Foundation

/// Shared "is an automatic backup due today, and has one already claimed
/// it" check used by both of auto-backup's two independent triggers:
///
/// - BackgroundBackupScheduler's BGTaskScheduler handler — genuine
///   background execution, but opportunistic: iOS may run it hours late,
///   or skip a day entirely if the app is never backgrounded long enough.
/// - PanamApp's on-scenePhase-active check — a reliable backstop that
///   can't fire while the app is fully closed, but is guaranteed to catch
///   up the next time the app is actually opened on or after the
///   configured hour.
///
/// Both call `claimIfDue()` before running the backup, never after —
/// whichever asks first writes `lastAutoBackupDateKey` immediately, so if
/// the two happen to fire close together (e.g. a background run lands
/// right as the user opens the app), the second caller sees today already
/// claimed and skips instead of backing up twice. This is a plain
/// check-then-set against UserDefaults, not a lock — good enough for two
/// triggers on one device for one user, not built to survive a genuine
/// concurrent race.
enum AutoBackupCoordinator {
    /// Checks whether auto-backup is on, the configured hour has passed
    /// for today, and nothing has claimed today yet — and if all three
    /// hold, immediately marks today claimed and returns true. Returns
    /// false (claiming nothing) the moment any condition fails.
    static func claimIfDue(now: Date = .now) -> Bool {
        let defaults = UserDefaults.standard

        guard defaults.object(forKey: AppSettings.autoBackupEnabledKey) as? Bool
            ?? AppSettings.autoBackupEnabledDefault
        else { return false }

        let hour = defaults.object(forKey: AppSettings.autoBackupHourKey) as? Int
            ?? AppSettings.autoBackupHourDefault
        guard Calendar.current.component(.hour, from: now) >= hour else { return false }

        let lastRun = defaults.object(forKey: AppSettings.lastAutoBackupDateKey) as? Date
        if let lastRun, Calendar.current.isDate(lastRun, inSameDayAs: now) {
            return false
        }

        defaults.set(now, forKey: AppSettings.lastAutoBackupDateKey)
        return true
    }
}
