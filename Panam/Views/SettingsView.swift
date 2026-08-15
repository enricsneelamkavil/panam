import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showingReorder = false

    @AppStorage(AppSettings.salaryDayKey)
    private var salaryDay = AppSettings.salaryDayDefault

    @AppStorage(AppSettings.salaryDayModeKey)
    private var salaryDayMode = AppSettings.salaryDayModeDefault

    @AppStorage(AppSettings.autoLockMinutesKey)
    private var autoLockMinutes = AppSettings.autoLockMinutesDefault

    @AppStorage(AppSettings.biometricLockEnabledKey)
    private var biometricLockEnabled = AppSettings.biometricLockEnabledDefault

    @AppStorage(AppSettings.dailyReminderEnabledKey)
    private var dailyReminderEnabled = AppSettings.dailyReminderEnabledDefault

    @AppStorage(AppSettings.dailyReminderHourKey)
    private var dailyReminderHour = AppSettings.dailyReminderHourDefault

    @AppStorage(AppSettings.dailyReminderMinuteKey)
    private var dailyReminderMinute = AppSettings.dailyReminderMinuteDefault

    /// DatePicker needs a Date binding, but the setting itself is stored as
    /// a plain hour/minute pair (no meaningful "day" — it's a daily
    /// recurring time, not a one-off moment) — this bridges the two
    /// without a third piece of stored state to keep in sync. Today's date
    /// is an arbitrary anchor; only the hour/minute components ever get
    /// read back out of it.
    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: dailyReminderHour, minute: dailyReminderMinute, second: 0, of: .now
                ) ?? .now
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                dailyReminderHour = components.hour ?? AppSettings.dailyReminderHourDefault
                dailyReminderMinute = components.minute ?? AppSettings.dailyReminderMinuteDefault
                if dailyReminderEnabled {
                    NotificationManager.shared.scheduleDailyReminder(hour: dailyReminderHour, minute: dailyReminderMinute)
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Salary Day", selection: $salaryDayMode) {
                        Text("1st of month").tag("first")
                        Text("Last day of month").tag("last")
                        Text("Custom").tag("custom")
                    }

                    if salaryDayMode == "custom" {
                        Stepper("Day: \(salaryDay)", value: $salaryDay, in: 1...31)
                    }
                } footer: {
                    Text("The day your salary arrives — the Salary Cycle summary runs from this day to the day before it next month.")
                }

                Section {
                    Button {
                        showingReorder = true
                    } label: {
                        HStack {
                            Text("Reorder Home")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Change the order of — or hide — sections on the Dashboard's Today tab.")
                }

                Section {
                    Toggle("Require Face ID / Passcode", isOn: $biometricLockEnabled)

                    Picker("Auto-Lock After", selection: $autoLockMinutes) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("Never").tag(0)
                    }
                }

                Section {
                    Toggle("Daily Reminder", isOn: $dailyReminderEnabled)
                        .onChange(of: dailyReminderEnabled) { _, isOn in
                            if isOn {
                                Task {
                                    await NotificationManager.shared.requestAuthorizationIfNeeded()
                                    NotificationManager.shared.scheduleDailyReminder(hour: dailyReminderHour, minute: dailyReminderMinute)
                                }
                            } else {
                                NotificationManager.shared.cancelDailyReminder()
                            }
                        }

                    if dailyReminderEnabled {
                        DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("A daily notification reminding you to log today's transactions. Off by default — not everyone wants a nudge.")
                }

            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingReorder) {
                DashboardReorderView()
            }
        }
    }
}

#Preview {
    SettingsView()
}
