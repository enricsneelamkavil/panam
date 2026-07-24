import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.salaryDayKey)
    private var salaryDay = AppSettings.salaryDayDefault

    @AppStorage(AppSettings.salaryDayModeKey)
    private var salaryDayMode = AppSettings.salaryDayModeDefault

    @AppStorage(AppSettings.autoLockMinutesKey)
    private var autoLockMinutes = AppSettings.autoLockMinutesDefault

    @AppStorage(AppSettings.biometricLockEnabledKey)
    private var biometricLockEnabled = AppSettings.biometricLockEnabledDefault

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
                    Toggle("Require Face ID / Passcode", isOn: $biometricLockEnabled)

                    Picker("Auto-Lock After", selection: $autoLockMinutes) {
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("Never").tag(0)
                    }
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
        }
    }
}

#Preview {
    SettingsView()
}
