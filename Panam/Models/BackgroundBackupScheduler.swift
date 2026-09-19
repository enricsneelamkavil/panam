//
//  BackgroundBackupScheduler.swift
//  Panam
//

import Foundation
import SwiftData
import BackgroundTasks
import GoogleSignIn

/// Schedules and runs the daily Drive backup via `BGTaskScheduler`, iOS's
/// native background-task API — not a custom timer or foreground-only
/// mechanism. When `AppSettings.autoBackupEnabledKey` is on, a
/// `BGAppRefreshTaskRequest` is (re)submitted for the next occurrence of
/// `AppSettings.autoBackupHourKey` every time the app runs the task, so the
/// schedule keeps renewing itself day after day.
///
/// Important: `BGTaskScheduler` timing is opportunistic, not exact — iOS
/// decides the actual run time based on device usage patterns, battery
/// state, and background activity budget, and it may run hours later than
/// the configured hour (or, rarely, be skipped entirely if the app is never
/// backgrounded). That drift is normal `BGTaskScheduler` behavior, not a bug
/// in this implementation — there is no API for an exact background firing
/// time on iOS.
enum BackgroundBackupScheduler {
    static let taskIdentifier = "enric.Plush.autoBackup"

    /// Registers the background task's launch handler. Must happen
    /// unconditionally, before the app finishes launching — BGTaskScheduler
    /// requires registration up front even if the feature is currently
    /// toggled off, so call this from `PanamApp.init()` every launch.
    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: appRefreshTask, container: container)
        }
    }

    /// Cancels any pending request and, if auto-backup is enabled, submits a
    /// fresh one for the next occurrence of the configured hour. Safe to call
    /// any time the setting/hour changes and again after every run — each
    /// call fully replaces the previous request.
    static func scheduleNext() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)

        guard UserDefaults.standard.object(forKey: AppSettings.autoBackupEnabledKey) as? Bool
            ?? AppSettings.autoBackupEnabledDefault
        else { return }

        let hour = UserDefaults.standard.object(forKey: AppSettings.autoBackupHourKey) as? Int
            ?? AppSettings.autoBackupHourDefault

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = nextOccurrence(ofHour: hour)
        BGTaskScheduler.shared.submitTaskRequest(request) { _ in }
    }

    /// The next future date/time at the given hour — today if that hour
    /// hasn't passed yet, otherwise tomorrow. `earliestBeginDate` only means
    /// "not before this" — the actual run can land well after it.
    private static func nextOccurrence(ofHour hour: Int) -> Date {
        let calendar = Calendar.current
        let now = Date.now
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = 0
        components.second = 0
        let candidate = calendar.date(from: components) ?? now
        return candidate > now ? candidate : (calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate)
    }

    private static func handle(task: BGAppRefreshTask, container: ModelContainer) {
        // Scheduled up front, not after the backup finishes — if this run
        // gets cut off by the expiration handler below, tomorrow's backup
        // is still on the calendar.
        scheduleNext()

        let work = Task {
            // Claimed here, before doing any work — see AutoBackupCoordinator.
            // PanamApp's on-active check shares this same claim, so whichever
            // of the two triggers gets here first for today is the one that
            // actually runs; if the foreground check already claimed today
            // (e.g. the app was opened and backed up before this background
            // task ever got a chance to fire), this just completes as a no-op.
            guard AutoBackupCoordinator.claimIfDue() else {
                task.setTaskCompleted(success: true)
                return
            }
            await restorePreviousGoogleSignInIfNeeded()
            let context = ModelContext(container)
            await DriveBackupManager().backupNow(context: context)
            task.setTaskCompleted(success: true)
        }

        // Best-effort: marks the Task cancelled so it can stop at its next
        // suspension point. iOS gives BGAppRefreshTask only a short window,
        // so a slow network call may still get cut off mid-flight regardless.
        task.expirationHandler = {
            work.cancel()
        }
    }

    /// The background launch doesn't go through PanamApp's `.task` (that's
    /// SwiftUI view lifecycle, which never mounts during a headless
    /// background task run) — so GIDSignIn's previous session has to be
    /// restored explicitly here before `DriveBackupManager` can use it.
    private static func restorePreviousGoogleSignInIfNeeded() async {
        guard GIDSignIn.sharedInstance.currentUser == nil else { return }
        await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { _, _ in
                continuation.resume()
            }
        }
    }
}
