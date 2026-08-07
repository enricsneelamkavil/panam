//
//  DriveBackupManager.swift
//  Panam
//

import Foundation
import Observation
import SwiftData
import GoogleSignIn

// MARK: - Errors

enum DriveBackupError: LocalizedError {
    case notSignedIn
    case tokenUnavailable
    case http(Int, String)
    case decoding
    case noBackupFound

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with Google first."
        case .tokenUnavailable:
            return "Couldn't refresh the Google access token. Try signing out and back in."
        case .http(let code, let message):
            return "Drive API error \(code): \(message)"
        case .decoding:
            return "Couldn't read the response from Drive."
        case .noBackupFound:
            return "No backup file was found in Drive."
        }
    }
}

// MARK: - Backup payload (Codable mirrors of the @Model types)
//
// Every cross-reference (e.g. a Transaction's account) is stored as the
// referenced record's `backupID` rather than a SwiftData relationship —
// relationships aren't Codable and don't survive a round trip through JSON.
// MoneyEvent is deliberately not mirrored here: it's a derived read-mirror
// that DriveBackupManager.restore(context:) regenerates via the existing
// MoneyEventMigration logic instead of backing it up directly.

/// Safely reads a possibly-dangling Transaction relationship's backupID.
/// TransactionOrphanCleanup should mean this never actually finds a stale
/// reference, but this is the second line of defense: reading an
/// *attribute* like `backupID` off a Transaction whose backing row was
/// deleted elsewhere crashes ("this model instance was invalidated..."),
/// while reading `persistentModelID` off that same stale reference does
/// not (SwiftData keeps identity metadata independent of a row's
/// attribute data) — so membership in a fresh, definitely-valid ID set is
/// checked first, and `backupID` is only ever read once that's confirmed.
/// If the reference is dangling, this degrades to `nil` instead of
/// crashing the whole backup.
private func safeBackupID(_ transaction: Transaction?, validTransactionIDs: Set<PersistentIdentifier>) -> UUID? {
    guard let transaction, validTransactionIDs.contains(transaction.persistentModelID) else { return nil }
    return transaction.backupID
}

nonisolated struct BackupPayload: Codable {
    var version: Int = 1
    var exportedAt: Date
    var accounts: [AccountBackup]
    var categories: [CategoryBackup]
    var transactions: [TransactionBackup]
    var people: [PersonBackup]
    var recurringPayments: [RecurringPaymentBackup]
    var recurringOccurrences: [RecurringOccurrenceBackup]
    var investments: [InvestmentBackup]
    var investmentOccurrences: [InvestmentOccurrenceBackup]
    var lendingEntries: [LendingEntryBackup]
    var creditCardEMIs: [CreditCardEMIBackup]
    var emiInstallments: [EMIInstallmentBackup]
    var cardPayments: [CardPaymentBackup]
    var splitAllocations: [SplitAllocationBackup]
    var loans: [LoanBackup]
    var loanInstallments: [LoanInstallmentBackup]
}

nonisolated struct AccountBackup: Codable {
    var backupID: UUID
    var name: String
    var type: AccountType
    var balance: Double
    var creditLimit: Double?
    var statementDay: Int?
    var dueDay: Int?
    var network: CardNetwork?
    var annualFeeAmount: Double?
    var feeWaiverSpendTarget: Double?
    var feeYearStartDate: Date?
    var createdAt: Date
    var lastFourDigits: String?

    init(_ m: Account) {
        backupID = m.backupID
        name = m.name
        type = m.type
        balance = m.balance
        creditLimit = m.creditLimit
        statementDay = m.statementDay
        dueDay = m.dueDay
        network = m.network
        annualFeeAmount = m.annualFeeAmount
        feeWaiverSpendTarget = m.feeWaiverSpendTarget
        feeYearStartDate = m.feeYearStartDate
        createdAt = m.createdAt
        lastFourDigits = m.lastFourDigits
    }
}

nonisolated struct CategoryBackup: Codable {
    var backupID: UUID
    var name: String
    var icon: String
    var isPreset: Bool
    var groupName: String?

    init(_ m: Category) {
        backupID = m.backupID
        name = m.name
        icon = m.icon
        isPreset = m.isPreset
        groupName = m.groupName
    }
}

nonisolated struct TransactionBackup: Codable {
    var backupID: UUID
    var amount: Double
    var date: Date
    var note: String
    var type: TransactionType
    var merchantName: String?
    var accountID: UUID?
    var toAccountID: UUID?
    var categoryID: UUID?
    var paymentMethod: PaymentMethod?
    var upiApp: String?
    var isSplit: Bool
    var myPortionAmount: Double?
    var isLendingRepayment: Bool
    var isCardPaymentSettlement: Bool

    init(_ m: Transaction) {
        backupID = m.backupID
        amount = m.amount
        date = m.date
        note = m.note
        type = m.type
        merchantName = m.merchantName
        accountID = m.account?.backupID
        toAccountID = m.toAccount?.backupID
        categoryID = m.category?.backupID
        paymentMethod = m.paymentMethod
        upiApp = m.upiApp
        isSplit = m.isSplit
        myPortionAmount = m.myPortionAmount
        isLendingRepayment = m.isLendingRepayment
        isCardPaymentSettlement = m.isCardPaymentSettlement
    }
}

nonisolated struct PersonBackup: Codable {
    var backupID: UUID
    var name: String
    var createdAt: Date

    init(_ m: Person) {
        backupID = m.backupID
        name = m.name
        createdAt = m.createdAt
    }
}

nonisolated struct RecurringPaymentBackup: Codable {
    var backupID: UUID
    var name: String
    var expectedAmount: Double
    var cadence: Cadence
    var startDate: Date
    var categoryID: UUID?
    var accountID: UUID?
    var isSubscription: Bool
    var isNecessary: Bool?
    var isActive: Bool
    var autopayEnabled: Bool
    var isIncome: Bool
    var cancelledDate: Date?
    var personID: UUID?

    init(_ m: RecurringPayment) {
        backupID = m.backupID
        name = m.name
        expectedAmount = m.expectedAmount
        cadence = m.cadence
        startDate = m.startDate
        categoryID = m.category?.backupID
        accountID = m.account?.backupID
        isSubscription = m.isSubscription
        isNecessary = m.isNecessary
        isActive = m.isActive
        autopayEnabled = m.autopayEnabled
        isIncome = m.isIncome
        cancelledDate = m.cancelledDate
        personID = m.person?.backupID
    }
}

nonisolated struct RecurringOccurrenceBackup: Codable {
    var backupID: UUID
    var dueDate: Date
    var expectedAmount: Double
    var actualAmount: Double?
    var isPaid: Bool
    var paidDate: Date?
    var linkedTransactionID: UUID?
    var parentID: UUID?

    init(_ m: RecurringOccurrence, validTransactionIDs: Set<PersistentIdentifier>) {
        backupID = m.backupID
        dueDate = m.dueDate
        expectedAmount = m.expectedAmount
        actualAmount = m.actualAmount
        isPaid = m.isPaid
        paidDate = m.paidDate
        linkedTransactionID = safeBackupID(m.linkedTransaction, validTransactionIDs: validTransactionIDs)
        parentID = m.parent?.backupID
    }
}

nonisolated struct InvestmentBackup: Codable {
    var backupID: UUID
    var instrumentType: InstrumentType
    var name: String
    var amount: Double
    var date: Date
    var note: String
    var accountID: UUID?
    var linkedTransactionID: UUID?
    var isRecurring: Bool
    var isActive: Bool
    var cadence: Cadence?
    var autopayEnabled: Bool
    var priorAmount: Double

    init(_ m: Investment, validTransactionIDs: Set<PersistentIdentifier>) {
        backupID = m.backupID
        instrumentType = m.instrumentType
        name = m.name
        amount = m.amount
        date = m.date
        note = m.note
        accountID = m.account?.backupID
        linkedTransactionID = safeBackupID(m.linkedTransaction, validTransactionIDs: validTransactionIDs)
        isRecurring = m.isRecurring
        isActive = m.isActive
        cadence = m.cadence
        autopayEnabled = m.autopayEnabled
        priorAmount = m.priorAmount
    }
}

nonisolated struct InvestmentOccurrenceBackup: Codable {
    var backupID: UUID
    var dueDate: Date
    var expectedAmount: Double
    var actualAmount: Double?
    var isContributed: Bool
    var contributedDate: Date?
    var linkedTransactionID: UUID?
    var parentID: UUID?

    init(_ m: InvestmentOccurrence, validTransactionIDs: Set<PersistentIdentifier>) {
        backupID = m.backupID
        dueDate = m.dueDate
        expectedAmount = m.expectedAmount
        actualAmount = m.actualAmount
        isContributed = m.isContributed
        contributedDate = m.contributedDate
        linkedTransactionID = safeBackupID(m.linkedTransaction, validTransactionIDs: validTransactionIDs)
        parentID = m.parent?.backupID
    }
}

nonisolated struct LendingEntryBackup: Codable {
    var backupID: UUID
    var amount: Double
    var date: Date
    var note: String
    var kind: LendingKind
    var personID: UUID?
    var linkedTransactionID: UUID?
    var sourceTransactionID: UUID?

    init(_ m: LendingEntry, validTransactionIDs: Set<PersistentIdentifier>) {
        backupID = m.backupID
        amount = m.amount
        date = m.date
        note = m.note
        kind = m.kind
        personID = m.person?.backupID
        linkedTransactionID = safeBackupID(m.linkedTransaction, validTransactionIDs: validTransactionIDs)
        sourceTransactionID = safeBackupID(m.sourceTransaction, validTransactionIDs: validTransactionIDs)
    }
}

nonisolated struct CreditCardEMIBackup: Codable {
    var backupID: UUID
    var name: String
    var accountID: UUID?
    var principalAmount: Double
    var monthlyAmount: Double
    var tenureMonths: Int
    var startDate: Date
    var isActive: Bool

    init(_ m: CreditCardEMI) {
        backupID = m.backupID
        name = m.name
        accountID = m.account?.backupID
        principalAmount = m.principalAmount
        monthlyAmount = m.monthlyAmount
        tenureMonths = m.tenureMonths
        startDate = m.startDate
        isActive = m.isActive
    }
}

nonisolated struct EMIInstallmentBackup: Codable {
    var backupID: UUID
    var installmentNumber: Int
    var dueDate: Date
    var amount: Double
    var isPaid: Bool
    var paidDate: Date?
    var linkedTransactionID: UUID?
    var parentID: UUID?

    init(_ m: EMIInstallment, validTransactionIDs: Set<PersistentIdentifier>) {
        backupID = m.backupID
        installmentNumber = m.installmentNumber
        dueDate = m.dueDate
        amount = m.amount
        isPaid = m.isPaid
        paidDate = m.paidDate
        linkedTransactionID = safeBackupID(m.linkedTransaction, validTransactionIDs: validTransactionIDs)
        parentID = m.parent?.backupID
    }
}

nonisolated struct CardPaymentBackup: Codable {
    var backupID: UUID
    var type: CardPaymentType
    var amount: Double
    var feeAmount: Double?
    var extraUnloggedAmount: Double
    var extraAmountCategoryID: UUID?
    var date: Date
    var note: String
    var cardID: UUID?
    var sourceAccountID: UUID?
    var cardTransactionID: UUID?
    var sourceTransactionID: UUID?
    var feeTransactionID: UUID?

    init(_ m: CardPayment, validTransactionIDs: Set<PersistentIdentifier>) {
        backupID = m.backupID
        type = m.type
        amount = m.amount
        feeAmount = m.feeAmount
        extraUnloggedAmount = m.extraUnloggedAmount
        extraAmountCategoryID = m.extraAmountCategory?.backupID
        date = m.date
        note = m.note
        cardID = m.card?.backupID
        sourceAccountID = m.sourceAccount?.backupID
        cardTransactionID = safeBackupID(m.cardTransaction, validTransactionIDs: validTransactionIDs)
        sourceTransactionID = safeBackupID(m.sourceTransaction, validTransactionIDs: validTransactionIDs)
        feeTransactionID = safeBackupID(m.feeTransaction, validTransactionIDs: validTransactionIDs)
    }
}

nonisolated struct SplitAllocationBackup: Codable {
    var backupID: UUID
    var amount: Double
    var personID: UUID?
    var transactionID: UUID?
    var lendingEntryID: UUID?

    init(_ m: SplitAllocation, validTransactionIDs: Set<PersistentIdentifier>) {
        backupID = m.backupID
        amount = m.amount
        personID = m.person?.backupID
        transactionID = safeBackupID(m.transaction, validTransactionIDs: validTransactionIDs)
        lendingEntryID = m.lendingEntry?.backupID
    }
}

nonisolated struct LoanBackup: Codable {
    var backupID: UUID
    var name: String
    var principalAmount: Double
    var interestRate: Double?
    var emiAmount: Double
    var tenureMonths: Int
    var startDate: Date
    var accountID: UUID?
    var isActive: Bool

    init(_ m: Loan) {
        backupID = m.backupID
        name = m.name
        principalAmount = m.principalAmount
        interestRate = m.interestRate
        emiAmount = m.emiAmount
        tenureMonths = m.tenureMonths
        startDate = m.startDate
        accountID = m.account?.backupID
        isActive = m.isActive
    }
}

nonisolated struct LoanInstallmentBackup: Codable {
    var backupID: UUID
    var installmentNumber: Int
    var dueDate: Date
    var amount: Double
    var isPaid: Bool
    var paidDate: Date?
    var linkedTransactionID: UUID?
    var parentID: UUID?

    init(_ m: LoanInstallment, validTransactionIDs: Set<PersistentIdentifier>) {
        backupID = m.backupID
        installmentNumber = m.installmentNumber
        dueDate = m.dueDate
        amount = m.amount
        isPaid = m.isPaid
        paidDate = m.paidDate
        linkedTransactionID = safeBackupID(m.linkedTransaction, validTransactionIDs: validTransactionIDs)
        parentID = m.parent?.backupID
    }
}

// MARK: - DriveBackupManager

/// Exports all app data (everything except MoneyEvent — see BackupPayload)
/// to a single JSON file in the signed-in Google account's hidden Drive
/// "app data" folder, and can restore from it. Uses the Drive v3 REST API
/// directly over the OAuth access token from GIDSignIn (drive.appdata
/// scope, granted during GmailAuthManager.signIn()) — no Drive SDK needed
/// for a single-file, app-private use case this narrow.
@Observable
final class DriveBackupManager {
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    /// Persisted locally (UserDefaults) — purely informational, shown in
    /// the Backup & Restore screen. Not read by any backup/restore logic.
    var lastBackupDate: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastBackupDateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastBackupDateKey) }
    }

    private static let lastBackupDateKey = "driveBackupLastDate"
    private static let backupFileName = "panam_backup.json"
    private static let filesBase = "https://www.googleapis.com/drive/v3/files"
    private static let uploadBase = "https://www.googleapis.com/upload/drive/v3/files"
    private static let multipartBoundary = "PanamBackupBoundary"

    // MARK: Public API

    /// Builds the JSON export and writes it to Drive's appDataFolder,
    /// overwriting the existing "panam_backup.json" in place if one
    /// already exists (files.update) rather than ever creating a second
    /// file — only falls back to files.create when none is found.
    func backupNow(context: ModelContext) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let payload = Self.makePayload(context: context)
            let data = try Self.encode(payload)
            let token = try await Self.currentAccessToken()

            if let existingID = try await Self.findExistingFileID(accessToken: token) {
                try await Self.updateFile(fileID: existingID, data: data, accessToken: token)
            } else {
                try await Self.createFile(data: data, accessToken: token)
            }
            lastBackupDate = .now
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches "panam_backup.json" from Drive, decodes it, then destructively
    /// replaces all local data with its contents. Callers are responsible
    /// for confirming with the user first — this does not ask again.
    func restore(context: ModelContext) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let token = try await Self.currentAccessToken()
            guard let fileID = try await Self.findExistingFileID(accessToken: token) else {
                throw DriveBackupError.noBackupFound
            }
            let data = try await Self.downloadFile(fileID: fileID, accessToken: token)
            let payload = try Self.decode(data)
            try Self.apply(payload, context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Payload building

    private static func makePayload(context: ModelContext) -> BackupPayload {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let recurringPayments = (try? context.fetch(FetchDescriptor<RecurringPayment>())) ?? []
        let recurringOccurrences = (try? context.fetch(FetchDescriptor<RecurringOccurrence>())) ?? []
        let investments = (try? context.fetch(FetchDescriptor<Investment>())) ?? []
        let investmentOccurrences = (try? context.fetch(FetchDescriptor<InvestmentOccurrence>())) ?? []
        let lendingEntries = (try? context.fetch(FetchDescriptor<LendingEntry>())) ?? []
        let creditCardEMIs = (try? context.fetch(FetchDescriptor<CreditCardEMI>())) ?? []
        let emiInstallments = (try? context.fetch(FetchDescriptor<EMIInstallment>())) ?? []
        let cardPayments = (try? context.fetch(FetchDescriptor<CardPayment>())) ?? []
        let splitAllocations = (try? context.fetch(FetchDescriptor<SplitAllocation>())) ?? []
        let loans = (try? context.fetch(FetchDescriptor<Loan>())) ?? []
        let loanInstallments = (try? context.fetch(FetchDescriptor<LoanInstallment>())) ?? []

        // Built once from this same fresh `transactions` fetch and threaded
        // through every struct that reads a Transaction relationship — see
        // safeBackupID's doc comment for why this is the safe way to detect
        // a dangling reference instead of just checking for nil.
        let validTransactionIDs = Set(transactions.map(\.persistentModelID))

        return BackupPayload(
            exportedAt: .now,
            accounts: accounts.map(AccountBackup.init),
            categories: categories.map(CategoryBackup.init),
            transactions: transactions.map(TransactionBackup.init),
            people: people.map(PersonBackup.init),
            recurringPayments: recurringPayments.map(RecurringPaymentBackup.init),
            recurringOccurrences: recurringOccurrences.map { RecurringOccurrenceBackup($0, validTransactionIDs: validTransactionIDs) },
            investments: investments.map { InvestmentBackup($0, validTransactionIDs: validTransactionIDs) },
            investmentOccurrences: investmentOccurrences.map { InvestmentOccurrenceBackup($0, validTransactionIDs: validTransactionIDs) },
            lendingEntries: lendingEntries.map { LendingEntryBackup($0, validTransactionIDs: validTransactionIDs) },
            creditCardEMIs: creditCardEMIs.map(CreditCardEMIBackup.init),
            emiInstallments: emiInstallments.map { EMIInstallmentBackup($0, validTransactionIDs: validTransactionIDs) },
            cardPayments: cardPayments.map { CardPaymentBackup($0, validTransactionIDs: validTransactionIDs) },
            splitAllocations: splitAllocations.map { SplitAllocationBackup($0, validTransactionIDs: validTransactionIDs) },
            loans: loans.map(LoanBackup.init),
            loanInstallments: loanInstallments.map { LoanInstallmentBackup($0, validTransactionIDs: validTransactionIDs) }
        )
    }

    // MARK: - Restore

    /// Two-pass restore: every record's non-relationship fields are enough
    /// to construct it (every relationship parameter on every model's
    /// init defaults to nil), so pass 1 creates and inserts every record
    /// across every type — building a `[UUID: Model]` map per type as it
    /// goes — before pass 2 walks the payload again wiring relationships
    /// via those maps. This sidesteps having to work out a dependency
    /// order between types by hand.
    private static func apply(_ payload: BackupPayload, context: ModelContext) throws {
        try clearExistingData(context: context)

        var accountsByID: [UUID: Account] = [:]
        for b in payload.accounts {
            let m = Account(name: b.name, type: b.type, balance: b.balance, creditLimit: b.creditLimit,
                             statementDay: b.statementDay, dueDay: b.dueDay, network: b.network)
            m.backupID = b.backupID
            m.annualFeeAmount = b.annualFeeAmount
            m.feeWaiverSpendTarget = b.feeWaiverSpendTarget
            m.feeYearStartDate = b.feeYearStartDate
            m.createdAt = b.createdAt
            m.lastFourDigits = b.lastFourDigits
            context.insert(m)
            accountsByID[b.backupID] = m
        }

        var categoriesByID: [UUID: Category] = [:]
        for b in payload.categories {
            let m = Category(name: b.name, icon: b.icon, isPreset: b.isPreset, groupName: b.groupName)
            m.backupID = b.backupID
            context.insert(m)
            categoriesByID[b.backupID] = m
        }

        var peopleByID: [UUID: Person] = [:]
        for b in payload.people {
            let m = Person(name: b.name)
            m.backupID = b.backupID
            m.createdAt = b.createdAt
            context.insert(m)
            peopleByID[b.backupID] = m
        }

        var transactionsByID: [UUID: Transaction] = [:]
        for b in payload.transactions {
            let m = Transaction(amount: b.amount, date: b.date, note: b.note, type: b.type)
            m.backupID = b.backupID
            m.merchantName = b.merchantName
            m.paymentMethod = b.paymentMethod
            m.upiApp = b.upiApp
            m.isSplit = b.isSplit
            m.myPortionAmount = b.myPortionAmount
            m.isLendingRepayment = b.isLendingRepayment
            m.isCardPaymentSettlement = b.isCardPaymentSettlement
            context.insert(m)
            transactionsByID[b.backupID] = m
        }

        var recurringPaymentsByID: [UUID: RecurringPayment] = [:]
        for b in payload.recurringPayments {
            let m = RecurringPayment(name: b.name, expectedAmount: b.expectedAmount, cadence: b.cadence,
                                      startDate: b.startDate, isSubscription: b.isSubscription,
                                      isNecessary: b.isNecessary, isActive: b.isActive)
            m.backupID = b.backupID
            m.autopayEnabled = b.autopayEnabled
            m.isIncome = b.isIncome
            m.cancelledDate = b.cancelledDate
            context.insert(m)
            recurringPaymentsByID[b.backupID] = m
        }

        var recurringOccurrencesByID: [UUID: RecurringOccurrence] = [:]
        for b in payload.recurringOccurrences {
            let m = RecurringOccurrence(dueDate: b.dueDate, expectedAmount: b.expectedAmount)
            m.backupID = b.backupID
            m.actualAmount = b.actualAmount
            m.isPaid = b.isPaid
            m.paidDate = b.paidDate
            context.insert(m)
            recurringOccurrencesByID[b.backupID] = m
        }

        var investmentsByID: [UUID: Investment] = [:]
        for b in payload.investments {
            let m = Investment(instrumentType: b.instrumentType, name: b.name, amount: b.amount, date: b.date,
                                note: b.note, isRecurring: b.isRecurring, cadence: b.cadence, isActive: b.isActive,
                                autopayEnabled: b.autopayEnabled, priorAmount: b.priorAmount)
            m.backupID = b.backupID
            context.insert(m)
            investmentsByID[b.backupID] = m
        }

        var investmentOccurrencesByID: [UUID: InvestmentOccurrence] = [:]
        for b in payload.investmentOccurrences {
            let m = InvestmentOccurrence(dueDate: b.dueDate, expectedAmount: b.expectedAmount)
            m.backupID = b.backupID
            m.actualAmount = b.actualAmount
            m.isContributed = b.isContributed
            m.contributedDate = b.contributedDate
            context.insert(m)
            investmentOccurrencesByID[b.backupID] = m
        }

        var lendingEntriesByID: [UUID: LendingEntry] = [:]
        for b in payload.lendingEntries {
            let m = LendingEntry(amount: b.amount, date: b.date, note: b.note, kind: b.kind)
            m.backupID = b.backupID
            context.insert(m)
            lendingEntriesByID[b.backupID] = m
        }

        var creditCardEMIsByID: [UUID: CreditCardEMI] = [:]
        for b in payload.creditCardEMIs {
            let m = CreditCardEMI(name: b.name, principalAmount: b.principalAmount, monthlyAmount: b.monthlyAmount,
                                   tenureMonths: b.tenureMonths, startDate: b.startDate, isActive: b.isActive)
            m.backupID = b.backupID
            context.insert(m)
            creditCardEMIsByID[b.backupID] = m
        }

        var emiInstallmentsByID: [UUID: EMIInstallment] = [:]
        for b in payload.emiInstallments {
            let m = EMIInstallment(installmentNumber: b.installmentNumber, dueDate: b.dueDate, amount: b.amount)
            m.backupID = b.backupID
            m.isPaid = b.isPaid
            m.paidDate = b.paidDate
            context.insert(m)
            emiInstallmentsByID[b.backupID] = m
        }

        var cardPaymentsByID: [UUID: CardPayment] = [:]
        for b in payload.cardPayments {
            let m = CardPayment(type: b.type, amount: b.amount, feeAmount: b.feeAmount,
                                 extraUnloggedAmount: b.extraUnloggedAmount, date: b.date, note: b.note)
            m.backupID = b.backupID
            context.insert(m)
            cardPaymentsByID[b.backupID] = m
        }

        var splitAllocationsByID: [UUID: SplitAllocation] = [:]
        for b in payload.splitAllocations {
            let m = SplitAllocation(amount: b.amount)
            m.backupID = b.backupID
            context.insert(m)
            splitAllocationsByID[b.backupID] = m
        }

        var loansByID: [UUID: Loan] = [:]
        for b in payload.loans {
            let m = Loan(name: b.name, principalAmount: b.principalAmount, interestRate: b.interestRate,
                         emiAmount: b.emiAmount, tenureMonths: b.tenureMonths, startDate: b.startDate,
                         isActive: b.isActive)
            m.backupID = b.backupID
            context.insert(m)
            loansByID[b.backupID] = m
        }

        var loanInstallmentsByID: [UUID: LoanInstallment] = [:]
        for b in payload.loanInstallments {
            let m = LoanInstallment(installmentNumber: b.installmentNumber, dueDate: b.dueDate, amount: b.amount)
            m.backupID = b.backupID
            m.isPaid = b.isPaid
            m.paidDate = b.paidDate
            context.insert(m)
            loanInstallmentsByID[b.backupID] = m
        }

        // Pass 2 — every record now exists, so every cross-reference can
        // be resolved via its backupID map.
        for b in payload.transactions {
            guard let m = transactionsByID[b.backupID] else { continue }
            m.account = b.accountID.flatMap { accountsByID[$0] }
            m.toAccount = b.toAccountID.flatMap { accountsByID[$0] }
            m.category = b.categoryID.flatMap { categoriesByID[$0] }
        }
        for b in payload.recurringPayments {
            guard let m = recurringPaymentsByID[b.backupID] else { continue }
            m.category = b.categoryID.flatMap { categoriesByID[$0] }
            m.account = b.accountID.flatMap { accountsByID[$0] }
            m.person = b.personID.flatMap { peopleByID[$0] }
        }
        for b in payload.recurringOccurrences {
            guard let m = recurringOccurrencesByID[b.backupID] else { continue }
            m.linkedTransaction = b.linkedTransactionID.flatMap { transactionsByID[$0] }
            m.parent = b.parentID.flatMap { recurringPaymentsByID[$0] }
        }
        for b in payload.investments {
            guard let m = investmentsByID[b.backupID] else { continue }
            m.account = b.accountID.flatMap { accountsByID[$0] }
            m.linkedTransaction = b.linkedTransactionID.flatMap { transactionsByID[$0] }
        }
        for b in payload.investmentOccurrences {
            guard let m = investmentOccurrencesByID[b.backupID] else { continue }
            m.linkedTransaction = b.linkedTransactionID.flatMap { transactionsByID[$0] }
            m.parent = b.parentID.flatMap { investmentsByID[$0] }
        }
        for b in payload.lendingEntries {
            guard let m = lendingEntriesByID[b.backupID] else { continue }
            m.person = b.personID.flatMap { peopleByID[$0] }
            m.linkedTransaction = b.linkedTransactionID.flatMap { transactionsByID[$0] }
            m.sourceTransaction = b.sourceTransactionID.flatMap { transactionsByID[$0] }
        }
        for b in payload.creditCardEMIs {
            guard let m = creditCardEMIsByID[b.backupID] else { continue }
            m.account = b.accountID.flatMap { accountsByID[$0] }
        }
        for b in payload.emiInstallments {
            guard let m = emiInstallmentsByID[b.backupID] else { continue }
            m.linkedTransaction = b.linkedTransactionID.flatMap { transactionsByID[$0] }
            m.parent = b.parentID.flatMap { creditCardEMIsByID[$0] }
        }
        for b in payload.cardPayments {
            guard let m = cardPaymentsByID[b.backupID] else { continue }
            m.extraAmountCategory = b.extraAmountCategoryID.flatMap { categoriesByID[$0] }
            m.card = b.cardID.flatMap { accountsByID[$0] }
            m.sourceAccount = b.sourceAccountID.flatMap { accountsByID[$0] }
            m.cardTransaction = b.cardTransactionID.flatMap { transactionsByID[$0] }
            m.sourceTransaction = b.sourceTransactionID.flatMap { transactionsByID[$0] }
            m.feeTransaction = b.feeTransactionID.flatMap { transactionsByID[$0] }
        }
        for b in payload.splitAllocations {
            guard let m = splitAllocationsByID[b.backupID] else { continue }
            m.person = b.personID.flatMap { peopleByID[$0] }
            m.transaction = b.transactionID.flatMap { transactionsByID[$0] }
            m.lendingEntry = b.lendingEntryID.flatMap { lendingEntriesByID[$0] }
        }
        for b in payload.loans {
            guard let m = loansByID[b.backupID] else { continue }
            m.account = b.accountID.flatMap { accountsByID[$0] }
        }
        for b in payload.loanInstallments {
            guard let m = loanInstallmentsByID[b.backupID] else { continue }
            m.linkedTransaction = b.linkedTransactionID.flatMap { transactionsByID[$0] }
            m.parent = b.parentID.flatMap { loansByID[$0] }
        }

        try context.save()

        // MoneyEvent isn't part of the backup — rebuild it fresh for the
        // restored data via the existing migration path.
        MoneyEventMigration.resetForRestore()
        MoneyEventMigration.runOneTimeMigration(context: context)
        MoneyEventMigration.runSourceTransactionBackfillIfNeeded(context: context)
    }

    /// Deletes every current record of every backed-up type, plus
    /// MoneyEvent (see `apply(_:context:)`), before repopulating from the
    /// backup. Order doesn't affect correctness — every relationship here
    /// defaults to nullify-on-delete — but going leaf-types-first avoids
    /// pointless nullify churn on records about to be deleted anyway.
    /// Fetches and deletes each record individually rather than using
    /// ModelContext's batch `delete(model:)` — that SQL-level batch delete
    /// hits a SwiftData constraint-trigger bug on some relationship shapes
    /// here ("mandatory OTO nullify inverse on LendingEntry/person"),
    /// failing outright. Object-graph deletes go through the normal
    /// relationship-aware pipeline instead and don't hit it.
    private static func clearExistingData(context: ModelContext) throws {
        func deleteAll<T: PersistentModel>(_ type: T.Type) throws {
            for record in try context.fetch(FetchDescriptor<T>()) {
                context.delete(record)
            }
        }
        try deleteAll(MoneyEvent.self)
        try deleteAll(SplitAllocation.self)
        try deleteAll(EMIInstallment.self)
        try deleteAll(LoanInstallment.self)
        try deleteAll(RecurringOccurrence.self)
        try deleteAll(InvestmentOccurrence.self)
        try deleteAll(LendingEntry.self)
        try deleteAll(CardPayment.self)
        try deleteAll(CreditCardEMI.self)
        try deleteAll(Loan.self)
        try deleteAll(RecurringPayment.self)
        try deleteAll(Investment.self)
        try deleteAll(Transaction.self)
        try deleteAll(Person.self)
        try deleteAll(Category.self)
        try deleteAll(Account.self)
        try context.save()
    }

    // MARK: - JSON

    private static func encode(_ payload: BackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private static func decode(_ data: Data) throws -> BackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(BackupPayload.self, from: data)
        } catch {
            throw DriveBackupError.decoding
        }
    }

    // MARK: - Auth

    private static func currentAccessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw DriveBackupError.notSignedIn
        }
        return try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshedUser, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token = refreshedUser?.accessToken.tokenString {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: DriveBackupError.tokenUnavailable)
                }
            }
        }
    }

    // MARK: - Drive REST calls

    private struct FileListResponse: Decodable {
        struct DriveFile: Decodable { let id: String; let name: String }
        let files: [DriveFile]
    }

    /// Searches only the hidden appDataFolder space for our one file by
    /// name — this is what guarantees a repeated backup overwrites in
    /// place (files.update below) instead of ever creating a duplicate.
    private static func findExistingFileID(accessToken: String) async throws -> String? {
        var components = URLComponents(string: filesBase)!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "name = '\(backupFileName)' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        let decoded = try JSONDecoder().decode(FileListResponse.self, from: data)
        return decoded.files.first?.id
    }

    private static func createFile(data: Data, accessToken: String) async throws {
        let url = URL(string: "\(uploadBase)?uploadType=multipart")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(multipartBoundary)", forHTTPHeaderField: "Content-Type")
        let metadata: [String: Any] = ["name": backupFileName, "parents": ["appDataFolder"]]
        request.httpBody = try multipartBody(metadata: metadata, fileData: data)
        _ = try await send(request)
    }

    /// Overwrites the given file's content in place. Never touches
    /// `parents` — the file already lives in appDataFolder.
    private static func updateFile(fileID: String, data: Data, accessToken: String) async throws {
        let url = URL(string: "\(uploadBase)/\(fileID)?uploadType=multipart")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(multipartBoundary)", forHTTPHeaderField: "Content-Type")
        let metadata: [String: Any] = ["name": backupFileName]
        request.httpBody = try multipartBody(metadata: metadata, fileData: data)
        _ = try await send(request)
    }

    private static func downloadFile(fileID: String, accessToken: String) async throws -> Data {
        let url = URL(string: "\(filesBase)/\(fileID)?alt=media")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    /// Drive's multipart/related upload format: a JSON metadata part
    /// followed by the file content part, separated by the boundary.
    private static func multipartBody(metadata: [String: Any], fileData: Data) throws -> Data {
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
        var body = Data()
        body.append("--\(multipartBoundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataJSON)
        body.append("\r\n--\(multipartBoundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(multipartBoundary)--".data(using: .utf8)!)
        return body
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DriveBackupError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw DriveBackupError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "unknown error")
        }
        return data
    }
}
