import Foundation

/// Keys and defaults for app-wide settings stored via @AppStorage.
enum AppSettings {
    static let salaryDayKey = "salaryDay"
    static let salaryDayDefault = 1          // 1–31

    static let autoLockMinutesKey = "autoLockMinutes"
    static let autoLockMinutesDefault = 5    // 0 = Never
}
