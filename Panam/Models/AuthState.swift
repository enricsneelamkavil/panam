import Foundation
import Observation

@Observable
final class AuthState {
    /// In-memory only — every launch and every return from background
    /// starts locked.
    var isUnlocked = false

    /// Persisted marker of the first successful unlock. Not used for gating
    /// (every launch requires unlock regardless) — kept for a future
    /// "Reset Panam" style feature.
    var hasCompletedFirstUnlock: Bool {
        get { KeychainStore.bool(forKey: Self.firstUnlockKey) }
        set { KeychainStore.set(newValue, forKey: Self.firstUnlockKey) }
    }

    /// Persisted marker that the user has completed Google sign-in at least
    /// once — gates PanamApp's one-time sign-in screen, shown before the
    /// Face ID/passcode flow ever runs. Deliberately separate from
    /// GmailAuthManager.signedInEmail, which reflects whether Gmail import
    /// is *currently* connected: disconnecting Gmail later (see
    /// EmailImportView) must never lock the user back out of the app, so
    /// only this one-time flag is checked at launch, and it's never reset.
    var hasCompletedGoogleLogin: Bool {
        get { KeychainStore.bool(forKey: Self.googleLoginKey) }
        set { KeychainStore.set(newValue, forKey: Self.googleLoginKey) }
    }

    private static let firstUnlockKey = "hasCompletedFirstUnlock"
    private static let googleLoginKey = "hasCompletedGoogleLogin"
}
