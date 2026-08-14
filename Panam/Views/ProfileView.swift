//
//  ProfileView.swift
//  Panam
//

import SwiftUI
import SwiftData
import GoogleSignIn

/// "Who am I signed in as" — separate from SettingsView's app-behavior
/// settings (salary day, biometric toggle, etc.). Guest mode offers an
/// additive upgrade to Google (existing local data untouched); Google mode
/// shows the account header, one compact "Email Management" card
/// (Dashboard-style — label + chevron, opens EmailManagementView, which
/// itself hosts the Transaction Mails / Statement Mails sub-flows — nothing
/// about senders, fetching, or review shows inline on this screen, one
/// level deep or two), a single consolidated Backup & Restore section, and
/// a real, prominent Logout. Presented from DashboardView's toolbar.
struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthState.self) private var authState
    @Environment(GmailAuthManager.self) private var gmailAuth
    @Environment(\.modelContext) private var modelContext

    // MARK: Guest → Google upgrade

    @State private var isSigningIn = false
    @State private var signInFailureMessage: String?

    // MARK: Card sheet

    @State private var showingEmailManagementSheet = false

    // MARK: Backup & Restore (moved from BackupRestoreView)

    @State private var driveBackupManager = DriveBackupManager()
    @State private var showingRestoreConfirmation = false

    @AppStorage(AppSettings.autoBackupEnabledKey)
    private var autoBackupEnabled = AppSettings.autoBackupEnabledDefault

    @AppStorage(AppSettings.autoBackupHourKey)
    private var autoBackupHour = AppSettings.autoBackupHourDefault

    private static let backupDateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    /// "3:00 AM" style label for a 24-hour value, for the hour picker below.
    private static func hourLabel(_ hour: Int) -> String {
        let components = DateComponents(hour: hour, minute: 0)
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(.dateTime.hour().minute())
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                switch authState.authMode {
                case .google:
                    googleHeaderSection
                    emailManagementCard
                    backupRestoreSections
                    logoutSection
                case .guest:
                    guestSection
                case .none:
                    EmptyView()
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingEmailManagementSheet) {
                EmailManagementView()
            }
            .alert("Restore from Backup?", isPresented: $showingRestoreConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Restore", role: .destructive) {
                    Task { await driveBackupManager.restore(context: modelContext) }
                }
            } message: {
                Text("This replaces all current data in Panam with your last backup. This can't be undone.")
            }
        }
    }

    // MARK: - Guest mode

    private var guestSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("You're using Panam locally", systemImage: "person.crop.circle")
                    .font(.headline)

                Text("Sign in with Google to back up your data to Drive and import transactions from Gmail. This only adds to what's here — your local data stays exactly as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let signInFailureMessage {
                    Text(signInFailureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    upgradeToGoogle()
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
            }
            .padding(.vertical, 8)
        }
    }

    private func upgradeToGoogle() {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInFailureMessage = nil

        gmailAuth.signIn { success in
            isSigningIn = false
            if success {
                authState.authMode = .google
            } else {
                signInFailureMessage = "Sign-in failed. Please try again."
            }
        }
    }

    // MARK: - Google mode: account header

    private var profileImageURL: URL? {
        GIDSignIn.sharedInstance.currentUser?.profile?.imageURL(withDimension: 160)
    }

    private var googleHeaderSection: some View {
        Section {
            HStack(spacing: 16) {
                AsyncImage(url: profileImageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 56, height: 56)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    if let name = GIDSignIn.sharedInstance.currentUser?.profile?.name {
                        Text(name)
                            .font(.headline)
                    }
                    Text(gmailAuth.signedInEmail ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Google mode: compact card

    /// Dashboard-card styled — label + chevron only, matching
    /// DashboardView's dashboardCard() rows. Wrapped in a Section with
    /// cleared row background/insets so it renders as a floating card
    /// rather than a standard Form row. The only email-related entry point
    /// on this screen — Transaction Mails / Statement Mails live one level
    /// deeper, inside EmailManagementView.
    private var emailManagementCard: some View {
        Section {
            Button {
                showingEmailManagementSheet = true
            } label: {
                cardLabel(title: "Email Management")
            }
            .buttonStyle(.plain)
            .dashboardCard()
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func cardLabel(title: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Google mode: Backup & Restore
    //
    // Both actions live in one Section as plain list-row buttons (no
    // .borderedProminent pill on "Backup Now") — that pill was what made
    // the system row separator right beneath it look "broken": a rounded,
    // full-bleed colored button sitting directly above List's default thin
    // inset separator line reads as visually mismatched/disconnected, even
    // though the separator itself was just the normal one Form draws
    // between any two rows in a Section. Consistent plain-row styling for
    // both buttons removes that clash entirely, not just papers over it.

    @ViewBuilder
    private var backupRestoreSections: some View {
        Section {
            Button {
                Task { await driveBackupManager.backupNow(context: modelContext) }
            } label: {
                if driveBackupManager.isWorking {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    Text("Backup Now")
                }
            }
            .disabled(driveBackupManager.isWorking)

            if let lastBackupDate = driveBackupManager.lastBackupDate {
                LabeledContent("Last Backup", value: lastBackupDate.formatted(Self.backupDateFormat))
                    .foregroundStyle(.secondary)
            } else {
                Text("No backup yet on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Restore from Backup", role: .destructive) {
                showingRestoreConfirmation = true
            }
            .disabled(driveBackupManager.isWorking)

            if let errorMessage = driveBackupManager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Backup & Restore")
        } footer: {
            Text("Backups save your data to your private Google Drive. Restoring replaces everything on this device with your last backup.")
        }

        Section {
            Toggle("Auto Backup", isOn: $autoBackupEnabled)
                .onChange(of: autoBackupEnabled) { _, _ in
                    BackgroundBackupScheduler.scheduleNext()
                }

            if autoBackupEnabled {
                Picker("Backup Time", selection: $autoBackupHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(Self.hourLabel(hour)).tag(hour)
                    }
                }
                .onChange(of: autoBackupHour) { _, _ in
                    BackgroundBackupScheduler.scheduleNext()
                }
            }
        } footer: {
            Text("Backs up automatically once a day in the background, around the selected time. iOS decides the exact moment based on device usage and battery — the actual backup can land a few hours later than scheduled (or occasionally not run at all if the app is never backgrounded). That's normal background-task behavior, not a malfunction.")
        }
    }

    // MARK: - Google mode: Logout

    /// Filled, prominent, red — a critical account action, not a plain
    /// destructive list row like Restore above (that's still reversible by
    /// restoring again; logging out ends the whole session).
    private var logoutSection: some View {
        Section {
            Button("Logout", role: .destructive) {
                gmailAuth.signOut()
                authState.authMode = .none
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .frame(maxWidth: .infinity, alignment: .center)
        } footer: {
            Text("Signs out of Google entirely and returns to the sign-in screen. Your local data isn't affected.")
        }
    }
}

#Preview {
    ProfileView()
        .environment(AuthState())
        .environment(GmailAuthManager())
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
