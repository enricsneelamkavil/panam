import Foundation

/// One-time migration for users who already went through the old mandatory
/// Google-only login gate (see LoginGateView, formerly GoogleSignInGateView):
/// carries their legacy `"hasCompletedGoogleLogin"` Keychain flag forward
/// into the new `AuthState.authMode == .google`, so introducing the
/// guest/Google split in LoginGateView doesn't log anyone out or re-prompt
/// them. Runs at most once, gated by its own UserDefaults completion flag
/// (same pattern as BackupIDBackfill) — a later real Logout (ProfileView)
/// legitimately resets `authMode` back to `.none`, and this must never
/// clobber that by re-running.
enum AuthModeBackfill {
    private static let legacyGoogleLoginKey = "hasCompletedGoogleLogin"
    private static let completionKey = "authModeBackfillComplete"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: completionKey) }

        guard KeychainStore.bool(forKey: legacyGoogleLoginKey) else { return }

        let authState = AuthState()
        if authState.authMode == .none {
            authState.authMode = .google
        }
    }
}
