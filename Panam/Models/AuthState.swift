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

    private static let firstUnlockKey = "hasCompletedFirstUnlock"
}
