import Foundation
import Observation

/// How the user is currently authenticated with Panam. Persisted (see
/// AuthState.authMode) and decided once at LoginGateView.
enum AuthMode: String {
    /// No login-gate decision made yet — the fresh-install state, and what
    /// a real Logout (see ProfileView) resets back to.
    case none
    /// Using Panam fully locally — no Google account involved.
    case guest
    /// Signed in with Google — gmail.readonly + drive.appdata granted.
    case google
}

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

    /// The one-time decision made at LoginGateView — gates PanamApp's login
    /// screen, shown before the Face ID/passcode flow ever runs. `.guest`
    /// and `.google` both count as "past the gate"; only `.none` shows it.
    ///
    /// Deliberately a *stored* property (persisted via `didSet`, seeded from
    /// Keychain in `init()`) rather than a Keychain-backed computed one —
    /// @Observable only instruments real stored properties, so PanamApp's
    /// body can react directly when this changes (e.g. ProfileView's Logout
    /// setting it back to `.none`) instead of needing a separate manually-
    /// flipped @State flag.
    ///
    /// Separate from GmailAuthManager.signedInEmail, which reflects whether
    /// Gmail import is *currently* connected: that can go nil (e.g. a
    /// dropped Google session) without this resetting — only an explicit
    /// Logout in ProfileView resets `authMode`, and it's a real logout,
    /// not a per-feature disconnect.
    var authMode: AuthMode {
        didSet { KeychainStore.set(authMode.rawValue, forKey: Self.authModeKey) }
    }

    init() {
        authMode = AuthMode(rawValue: KeychainStore.string(forKey: Self.authModeKey) ?? "") ?? .none
    }

    private static let firstUnlockKey = "hasCompletedFirstUnlock"
    private static let authModeKey = "authMode"
}
