//
//  GoogleSignInGateView.swift
//  Panam
//

import SwiftUI

/// Full-screen gate shown once, before the very first Face ID/passcode
/// unlock ever runs — proves account ownership via Google sign-in. Purely a
/// one-time setup step: completing it flips AuthState.hasCompletedGoogleLogin
/// in the Keychain, so it's never shown again on this device, even offline
/// and even if Gmail import is later disconnected (see EmailImportView,
/// which only touches GmailAuthManager.signedInEmail, not this flag).
struct GoogleSignInGateView: View {
    let authState: AuthState
    let gmailAuth: GmailAuthManager
    let onComplete: () -> Void

    @State private var isSigningIn = false
    @State private var failureMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Welcome to Panam")
                .font(.title2.bold())

            Text("Sign in with Google once to set up Panam. After this, you'll unlock with Face ID or your passcode — no internet required.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let failureMessage {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                signIn()
            } label: {
                Group {
                    if isSigningIn {
                        ProgressView()
                    } else {
                        Text("Sign in with Google")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.appPrimary)
            .disabled(isSigningIn)
            .padding(.horizontal, 32)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .ignoresSafeArea()
    }

    private func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        failureMessage = nil

        gmailAuth.signIn { success in
            isSigningIn = false
            if success {
                authState.hasCompletedGoogleLogin = true
                onComplete()
            } else {
                failureMessage = "Sign-in failed. Please try again."
            }
        }
    }
}
