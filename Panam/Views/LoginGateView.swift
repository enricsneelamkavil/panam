//
//  LoginGateView.swift
//  Panam
//

import SwiftUI

/// Full-screen gate shown once, before the very first Face ID/passcode
/// unlock ever runs — offers a real choice of how to use Panam: fully local
/// as a guest, or signed in with Google (gmail.readonly + drive.appdata,
/// granted once, right here). Either choice sets AuthState.authMode and
/// proceeds past this gate for good; see ProfileView for switching from
/// guest to Google later, or logging out of Google back to this screen.
struct LoginGateView: View {
    let authState: AuthState
    let gmailAuth: GmailAuthManager

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

            Text("Use Panam fully locally as a guest, or sign in with Google to back up to Drive and import transactions from Gmail. Either way, you'll unlock with Face ID or your passcode after this.")
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

            VStack(spacing: 12) {
                Button {
                    signInWithGoogle()
                } label: {
                    Group {
                        if isSigningIn {
                            ProgressView()
                        } else {
                            Text("Continue with Google")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
                .disabled(isSigningIn)

                Button("Continue as Guest") {
                    continueAsGuest()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isSigningIn)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .ignoresSafeArea()
    }

    private func continueAsGuest() {
        authState.authMode = .guest
    }

    private func signInWithGoogle() {
        guard !isSigningIn else { return }
        isSigningIn = true
        failureMessage = nil

        gmailAuth.signIn { success in
            isSigningIn = false
            if success {
                authState.authMode = .google
            } else {
                failureMessage = "Sign-in failed. Please try again."
            }
        }
    }
}
