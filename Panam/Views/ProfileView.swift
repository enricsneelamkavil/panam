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
    @Environment(EmailFetchCoordinator.self) private var emailFetchCoordinator
    @Environment(\.modelContext) private var modelContext

    // MARK: Guest → Google upgrade

    @State private var isSigningIn = false
    @State private var signInFailureMessage: String?

    // MARK: Card sheet

    @State private var showingEmailManagementSheet = false
    /// Pending StatementAutoFetchProcessor notices — read fresh whenever
    /// this screen appears (ProfileView is presented as a sheet, so that's
    /// every time it's relevant) and again once Email Management is
    /// dismissed, since opening it is what marks them read.
    @State private var pendingAutoFetchNoticeCount = 0

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
            .onAppear {
                pendingAutoFetchNoticeCount = StatementAutoFetchStore.notices.count
            }
            .sheet(isPresented: $showingEmailManagementSheet, onDismiss: {
                pendingAutoFetchNoticeCount = StatementAutoFetchStore.notices.count
            }) {
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
                cardLabel(title: "Email Management", badgeCount: pendingAutoFetchNoticeCount)
            }
            .buttonStyle(.plain)
            .dashboardCard()

            // Persistent — reflects EmailFetchCoordinator's state directly,
            // so a fetch started inside Email Management (and still running,
            // or cancelled) stays visible here no matter how far back out of
            // that flow you've navigated. See EmailFetchCoordinator's doc
            // comment for why the fetch itself lives there rather than on
            // whichever sheet happened to start it.
            if emailFetchCoordinator.isFetching {
                FetchStatusPill(coordinator: emailFetchCoordinator)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func cardLabel(title: String, badgeCount: Int = 0) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.appPrimary, in: Capsule())
            }
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
            Text("Backs up automatically once a day, two ways: iOS may run it in the background around the selected time — timing isn't exact, and it can land hours late or get skipped some days, which is normal background-task behavior, not a malfunction — and if that hasn't happened yet, opening the app on or after that time backs up right then instead, silently, as a reliable catch-up. Either way counts as the day's backup, so it won't run a second time until tomorrow.")
        }
    }

    // MARK: - Google mode: Logout

    /// Filled, prominent, red, full-width, plain — a critical account
    /// action that reads as a real button, not a list row like Restore
    /// above. Lives as real Form row content (scrolls with everything
    /// else, no sticky positioning, no surface of its own) with
    /// .listRowBackground(Color.clear)/.listRowInsets(EdgeInsets()) so it
    /// reads as a plain full-bleed button rather than a boxed list row —
    /// same clash backupRestoreSections' comment above calls out for
    /// "Backup Now" — plus .listRowSeparator(.hidden), the modifier that
    /// was actually missing before: clearing a row's background/insets
    /// doesn't touch List's separator hairline, that's a distinct
    /// modifier, so without it a line still showed beneath the button.
    @ViewBuilder
    private var logoutSection: some View {
        // .frame(maxWidth: .infinity) has to be on the label content, not
        // chained onto the Button itself — .borderedProminent draws its
        // capsule background sized to the label's own reported width, so a
        // frame applied only to the outer Button (as Button(_:role:action:)
        // forces, since it can't be reached inside) widens the tap target
        // but leaves the visible red pill hugging the text. Same fix as
        // "Sign in with Google" above: use the label-closure initializer so
        // the frame lands on the Text before .buttonStyle ever sees it.
        Button(role: .destructive) {
            gmailAuth.signOut()
            authState.authMode = .none
        } label: {
            Text("Logout")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)

        Text("Signs out of Google entirely and returns to the sign-in screen. Your local data isn't affected.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}

// MARK: - Persistent fetch indicator

/// A slim status card for whichever batch fetch EmailFetchCoordinator is
/// currently running — "Fetching statements… 4 of 12" plus a determinate
/// bar and a Cancel button right there, so stopping it (or just checking on
/// it) never requires navigating back into Email Management first.
private struct FetchStatusPill: View {
    let coordinator: EmailFetchCoordinator

    private var kindLabel: String {
        switch coordinator.fetchType {
        case .transactions: return "Fetching transaction mails"
        case .statements: return "Fetching statements"
        case .dematStatements: return "Fetching demat statements"
        case nil: return "Fetching"
        }
    }

    private var progressText: String {
        coordinator.totalCount > 0
            ? "\(kindLabel)… \(coordinator.processedCount) of \(coordinator.totalCount)"
            : "\(kindLabel)…"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(coordinator.processedCount), total: Double(max(coordinator.totalCount, 1)))
            }
            Button("Cancel", role: .destructive) {
                coordinator.cancelFetch()
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#Preview {
    ProfileView()
        .environment(AuthState())
        .environment(GmailAuthManager())
        .environment(EmailFetchCoordinator())
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
