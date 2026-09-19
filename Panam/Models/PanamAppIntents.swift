//
//  PanamAppIntents.swift
//  Panam
//

import Foundation
import AppIntents
import SwiftData

// MARK: - App Entities

/// Exposes Panam Financial Snapshot summary to Siri and Apple Intelligence.
struct FinancialSnapshotEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Financial Snapshot"

    var id: String
    var netWorth: Double
    var totalCashBalance: Double
    var creditCardDebt: Double
    var investmentValue: Double
    var upcomingPaymentsCount: Int
    var upcomingPaymentsTotal: Double
    var summaryText: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(netWorth.formatted(.currency(code: "INR")))",
            subtitle: "Net Worth • Cash: \(totalCashBalance.formatted(.currency(code: "INR")))"
        )
    }

    static var defaultQuery = FinancialSnapshotQuery()
}

struct FinancialSnapshotQuery: EntityQuery {
    func entities(for ids: [FinancialSnapshotEntity.ID]) async throws -> [FinancialSnapshotEntity] {
        let snapshot = try await fetchSnapshot()
        return ids.contains(snapshot.id) ? [snapshot] : []
    }

    func suggestedEntities() async throws -> [FinancialSnapshotEntity] {
        let snapshot = try await fetchSnapshot()
        return [snapshot]
    }

    @MainActor
    private func fetchSnapshot() throws -> FinancialSnapshotEntity {
        let context = SharedModelContainer.main.mainContext

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let investments = (try? context.fetch(FetchDescriptor<Investment>())) ?? []

        var totalCash = 0.0
        var totalCredit = 0.0
        for account in accounts {
            if account.type == .bank || account.type == .cash || account.type == .wallet {
                totalCash += account.balance
            } else if account.type == .creditCard {
                totalCredit += account.balance
            }
        }

        var totalInvestments = 0.0
        for investment in investments {
            totalInvestments += investment.currentValue ?? investment.amount
        }

        let netWorth = (totalCash + totalInvestments) - totalCredit
        let summary = "Net worth: ₹\(Int(netWorth)). Cash balance: ₹\(Int(totalCash)), Credit debt: ₹\(Int(totalCredit)), Investments: ₹\(Int(totalInvestments))."

        return FinancialSnapshotEntity(
            id: "current_snapshot",
            netWorth: netWorth,
            totalCashBalance: totalCash,
            creditCardDebt: totalCredit,
            investmentValue: totalInvestments,
            upcomingPaymentsCount: 0,
            upcomingPaymentsTotal: 0,
            summaryText: summary
        )
    }
}

// MARK: - Siri App Intents

/// Siri Intent: "What's my financial snapshot in Panam?"
struct GetFinancialSnapshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Financial Snapshot"
    static var description = IntentDescription("Provides an instant financial snapshot including net worth, cash balance, credit card debt, and investments.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let context = SharedModelContainer.main.mainContext

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let investments = (try? context.fetch(FetchDescriptor<Investment>())) ?? []

        var totalCash = 0.0
        var totalCredit = 0.0
        for account in accounts {
            if account.type == .bank || account.type == .cash || account.type == .wallet {
                totalCash += account.balance
            } else if account.type == .creditCard {
                totalCredit += account.balance
            }
        }

        var totalInvestments = 0.0
        for investment in investments {
            totalInvestments += investment.currentValue ?? investment.amount
        }

        let netWorth = totalCash + totalInvestments - totalCredit

        let dialogText = """
        Here is your financial snapshot:
        • Net Worth: ₹\(Int(netWorth).formatted())
        • Total Cash: ₹\(Int(totalCash).formatted())
        • Credit Card Balance: ₹\(Int(totalCredit).formatted())
        • Investments: ₹\(Int(totalInvestments).formatted())
        """

        return .result(value: dialogText, dialog: IntentDialog(stringLiteral: dialogText))
    }
}

/// Siri Intent: "Log an expense in Panam"
struct LogTransactionIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Transaction"
    static var description = IntentDescription("Log a new financial transaction with Siri hands-free.")

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Merchant or Note")
    var note: String

    @Parameter(title: "Type", default: "expense")
    var type: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = SharedModelContainer.main.mainContext

        let isIncome = (type.lowercased() == "income")
        let transactionType: TransactionType = isIncome ? .income : .expense

        let transaction = Transaction(
            amount: amount,
            date: .now,
            note: note,
            type: transactionType
        )
        transaction.merchantName = note

        context.insert(transaction)
        try? context.save()

        let dialogText = "Logged \(isIncome ? "income" : "expense") of ₹\(Int(amount)) for \(note) in Panam."
        return .result(dialog: IntentDialog(stringLiteral: dialogText))
    }
}

// MARK: - App Shortcuts Provider

struct PanamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetFinancialSnapshotIntent(),
            phrases: [
                "What's my financial snapshot in \(.applicationName)?",
                "Check my money snapshot in \(.applicationName)",
                "How much money do I have in \(.applicationName)?",
                "Show my net worth in \(.applicationName)"
            ],
            shortTitle: "Financial Snapshot",
            systemImageName: "chart.pie.fill"
        )
        AppShortcut(
            intent: LogTransactionIntent(),
            phrases: [
                "Log a transaction in \(.applicationName)",
                "Log an expense in \(.applicationName)",
                "Add spending in \(.applicationName)"
            ],
            shortTitle: "Log Expense",
            systemImageName: "plus.circle.fill"
        )
    }
}
