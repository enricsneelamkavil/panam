//
//  BackupRestoreView.swift
//  Panam
//

import SwiftUI
import SwiftData

/// Backup all app data to (and restore from) a single JSON file in the
/// signed-in Google account's hidden Drive app-data folder. Pushed from
/// Settings.
struct BackupRestoreView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var driveBackupManager = DriveBackupManager()
    @State private var showingRestoreConfirmation = false

    @AppStorage(AppSettings.autoBackupEnabledKey)
    private var autoBackupEnabled = AppSettings.autoBackupEnabledDefault

    @AppStorage(AppSettings.autoBackupHourKey)
    private var autoBackupHour = AppSettings.autoBackupHourDefault

    private static let dateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)

    /// "3:00 AM" style label for a 24-hour value, for the hour picker below.
    private static func hourLabel(_ hour: Int) -> String {
        let components = DateComponents(hour: hour, minute: 0)
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(.dateTime.hour().minute())
    }

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await driveBackupManager.backupNow(context: modelContext) }
                } label: {
                    if driveBackupManager.isWorking {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Backup Now")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
                .disabled(driveBackupManager.isWorking)

                if let lastBackupDate = driveBackupManager.lastBackupDate {
                    LabeledContent("Last Backup", value: lastBackupDate.formatted(Self.dateFormat))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No backup yet on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Saves all your accounts, transactions, and other Panam data to a private file in your Google Drive — hidden from the regular Drive app, visible only to Panam.")
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

            Section {
                Button("Restore from Backup", role: .destructive) {
                    showingRestoreConfirmation = true
                }
                .disabled(driveBackupManager.isWorking)
            } footer: {
                Text("Replaces everything currently in Panam with what's in the backup file. Anything added since your last backup will be lost.")
            }

            if let errorMessage = driveBackupManager.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
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

#Preview {
    NavigationStack {
        BackupRestoreView()
    }
    .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
