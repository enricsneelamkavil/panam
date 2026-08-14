import Foundation

/// Keys and defaults for app-wide settings stored via @AppStorage.
enum AppSettings {
    static let salaryDayKey = "salaryDay"
    static let salaryDayDefault = 1          // 1–31

    static let salaryDayModeKey = "salaryDayMode"
    static let salaryDayModeDefault = "first" // "first" | "last" | "custom"

    static let autoLockMinutesKey = "autoLockMinutes"
    static let autoLockMinutesDefault = 5    // 0 = Never

    static let biometricLockEnabledKey = "biometricLockEnabled"
    static let biometricLockEnabledDefault = true

    /// Whether the daily Drive backup should run automatically in the
    /// background via BGTaskScheduler — see BackgroundBackupScheduler.
    static let autoBackupEnabledKey = "autoBackupEnabled"
    static let autoBackupEnabledDefault = false

    /// Target hour (24-hour, 0–23) for the automatic backup. iOS treats this
    /// as a hint, not a guarantee — see BackgroundBackupScheduler.
    static let autoBackupHourKey = "autoBackupHour"
    static let autoBackupHourDefault = 3

    /// Last calendar date an automatic backup actually ran, set by whichever
    /// trigger gets there first each day — BackgroundBackupScheduler's
    /// BGTaskScheduler handler, or PanamApp's on-scenePhase-active check.
    /// See AutoBackupCoordinator.claimIfDue: both read/write this same key
    /// so the second trigger to fire on a given day sees today's already
    /// claimed and skips, rather than backing up twice.
    static let lastAutoBackupDateKey = "lastAutoBackupDate"

    /// Newline-joined list of Gmail sender addresses/domains/keywords to search
    /// for transaction alert emails (e.g. "alerts@hdfcbank.net"). Seeded with a
    /// starting set of common Indian bank alert senders on first launch of the
    /// Email Import screen — from then on it's stored/edited exactly like any
    /// user-added term, via the same @AppStorage key.
    static let gmailSenderTermsKey = "gmailSenderTerms"
    static let gmailSenderTermsDefault = [
        "alerts@hdfcbank.bank.in",
        "nachautoemailer@hdfcbank.bank.in",
        "alerts@axis.bank.in",
        "alerts@dcb.bank.in",
        "onlinesbicard@sbicard.com",
        "alerts@notification.my.rbl.bank.in",
    ].joined(separator: "\n")

    /// Newline-joined list of Gmail senders/domains to search for statement
    /// emails (e.g. "e-Statement," "Monthly Statement"). Unlike
    /// gmailSenderTermsKey's per-transaction-alert senders, statement
    /// sender patterns vary a lot more bank to bank and there's no safe
    /// common starting set — seeded empty, filled in as you find them.
    static let statementSenderTermsKey = "gmailStatementSenderTerms"
    static let statementSenderTermsDefault = ""

    /// Splits a newline-joined sender-terms value (gmailSenderTermsKey /
    /// statementSenderTermsKey) into a trimmed, non-empty list — the same
    /// logic every sender-term screen already applies inline to its
    /// @AppStorage-backed raw string. Factored out here so non-View code
    /// (StatementAutoFetchProcessor, which reads the raw UserDefaults value
    /// directly since it can't use @AppStorage) can reuse it too.
    static func parseSenderTerms(_ raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
