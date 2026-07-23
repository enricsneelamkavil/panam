import Foundation
import Observation

/// App-wide privacy switch: when on, currency figures render as dots.
/// Injected into the environment from PlushApp.
@Observable
final class PrivacyState {
    private static let key = "amountsHidden"

    var amountsHidden: Bool {
        didSet { UserDefaults.standard.set(amountsHidden, forKey: Self.key) }
    }

    init() {
        amountsHidden = UserDefaults.standard.bool(forKey: Self.key)
    }
}
