//
//  GmailAuthManager.swift
//  Panam
//

import Foundation
import Observation
import GoogleSignIn
import UIKit

/// Wraps Google Sign-In for the Gmail import feature. Owns the connected
/// account's sign-in state; no message-fetching logic lives here yet.
@Observable
final class GmailAuthManager {
    static let clientID = "323017888629-31n5drtdfkqeereedhl3ea2h55368otg.apps.googleusercontent.com"

    private(set) var signedInEmail: String?

    init() {
        signedInEmail = GIDSignIn.sharedInstance.currentUser?.profile?.email
    }

    /// Call once at app launch, after configuring GIDSignIn, to silently
    /// restore a previous session across app restarts.
    func restorePreviousSignIn() {
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, _ in
            self?.signedInEmail = user?.profile?.email
        }
    }

    /// - Parameter completion: Reports whether sign-in actually succeeded —
    ///   used by the one-time Google sign-in gate at launch to know when to
    ///   proceed. Callers that already watch `signedInEmail` reactively
    ///   (e.g. EmailImportView) can omit it.
    func signIn(completion: ((Bool) -> Void)? = nil) {
        guard let rootViewController = Self.rootViewController else {
            completion?(false)
            return
        }

        GIDSignIn.sharedInstance.signIn(
            withPresenting: rootViewController,
            hint: nil,
            // gmail.readonly powers Email Import; drive.appdata is a narrow,
            // hidden-from-the-user's-Drive-UI scope used only by
            // DriveBackupManager to read/write our own single backup file.
            additionalScopes: [
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/drive.appdata",
            ]
        ) { [weak self] result, error in
            self?.signedInEmail = result?.user.profile?.email
            completion?(result != nil && error == nil)
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        signedInEmail = nil
    }

    private static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}
