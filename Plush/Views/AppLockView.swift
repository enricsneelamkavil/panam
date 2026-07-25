//
//  AppLockView.swift
//  Plush
//

import SwiftUI
import LocalAuthentication

/// Full-screen gate shown whenever the app is locked. Handles the very
/// first launch and every subsequent unlock identically — the only way
/// past it is a successful device-owner authentication.
struct AppLockView: View {
    let authState: AuthState

    @State private var isAuthenticating = false
    @State private var failureMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Plush is locked")
                .font(.title2.bold())

            Text("Unlock with Face ID or your device passcode.")
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

                Button("Try Again") {
                    authenticate()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .ignoresSafeArea()
        .onAppear(perform: authenticate)
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        failureMessage = nil

        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            isAuthenticating = false
            failureMessage = "Authentication isn't available. Set a device passcode to use Plush."
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Unlock Plush") { success, _ in
            Task { @MainActor in
                isAuthenticating = false
                if success {
                    authState.isUnlocked = true
                    if !authState.hasCompletedFirstUnlock {
                        authState.hasCompletedFirstUnlock = true
                    }
                } else {
                    failureMessage = "Couldn't verify it's you."
                }
            }
        }
    }
}
