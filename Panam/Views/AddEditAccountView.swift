//
//  AddEditAccountView.swift
//  Panam
//

import SwiftUI
import SwiftData

struct AddEditAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]

    /// The account being edited, or nil when creating a new one.
    var account: Account?

    @State private var name = ""
    @State private var type: AccountType = .bank
    @State private var balance: Double?
    @State private var creditLimit: Double?
    @State private var statementDay: Int?
    @State private var dueDay: Int?
    @State private var annualFeeAmount: Double?
    @State private var feeWaiverSpendTarget: Double?
    @State private var feeYearStartDate: Date = .now

    private var isEditing: Bool { account != nil }

    /// A Cash account other than the one being edited already exists.
    private var duplicateCashExists: Bool {
        accounts.contains { $0.type == .cash && $0.persistentModelID != account?.persistentModelID }
    }

    private var canSave: Bool {
        guard balance != nil else { return false }
        if type == .cash {
            return !duplicateCashExists
        }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if type != .cash {
                        TextField("Name", text: $name)
                    }

                    Picker("Type", selection: $type) {
                        Text("Bank").tag(AccountType.bank)
                        Text("Cash").tag(AccountType.cash)
                        Text("Wallet").tag(AccountType.wallet)
                        Text("Credit Card").tag(AccountType.creditCard)
                    }
                    .pickerStyle(.segmented)

                    if type == .cash && duplicateCashExists {
                        Text("A Cash account already exists — only one is allowed.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    TextField(
                        type == .creditCard ? "Current Outstanding" : "Balance",
                        value: $balance,
                        format: .number
                    )
                    .keyboardType(.decimalPad)
                }

                if type == .creditCard {
                    Section("Credit Card Details") {
                        TextField("Credit Limit", value: $creditLimit, format: .number)
                            .keyboardType(.decimalPad)

                        TextField("Statement Day (1–31)", value: $statementDay, format: .number)
                            .keyboardType(.numberPad)

                        TextField("Due Day (1–31)", value: $dueDay, format: .number)
                            .keyboardType(.numberPad)
                    }

                    Section {
                        TextField("Annual Fee Amount", value: $annualFeeAmount, format: .number)
                            .keyboardType(.decimalPad)

                        TextField("Spend Target to Waive It", value: $feeWaiverSpendTarget, format: .number)
                            .keyboardType(.decimalPad)

                        DatePicker("Fee Year Start Date", selection: $feeYearStartDate, displayedComponents: .date)
                    } header: {
                        Text("Annual Fee")
                    } footer: {
                        Text("All optional. Fee year start defaults to today if left as-is.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Account" : "New Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: populateFromAccount)
        }
    }

    private func populateFromAccount() {
        guard let account else { return }
        name = account.name
        type = account.type
        balance = account.balance
        creditLimit = account.creditLimit
        statementDay = account.statementDay
        dueDay = account.dueDay
        annualFeeAmount = account.annualFeeAmount
        feeWaiverSpendTarget = account.feeWaiverSpendTarget
        feeYearStartDate = account.feeYearStartDate ?? .now
    }

    private func save() {
        guard let balance else { return }
        guard type != .cash || !duplicateCashExists else { return }
        let trimmedName = type == .cash ? "Cash" : name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        // Clamp credit card day fields to 1–31; drop them for non-credit-card types.
        let clampedStatementDay = type == .creditCard ? statementDay.map { min(max($0, 1), 31) } : nil
        let clampedDueDay = type == .creditCard ? dueDay.map { min(max($0, 1), 31) } : nil
        let limit = type == .creditCard ? creditLimit : nil

        let resolvedAnnualFee = type == .creditCard ? annualFeeAmount : nil
        let resolvedFeeTarget = type == .creditCard ? feeWaiverSpendTarget : nil
        let resolvedFeeYearStart: Date? = (resolvedAnnualFee != nil || resolvedFeeTarget != nil)
            ? feeYearStartDate : nil

        if let account {
            account.name = trimmedName
            account.type = type
            account.balance = balance
            account.creditLimit = limit
            account.statementDay = clampedStatementDay
            account.dueDay = clampedDueDay
            account.annualFeeAmount = resolvedAnnualFee
            account.feeWaiverSpendTarget = resolvedFeeTarget
            account.feeYearStartDate = resolvedFeeYearStart
        } else {
            let newAccount = Account(
                name: trimmedName,
                type: type,
                balance: balance,
                creditLimit: limit,
                statementDay: clampedStatementDay,
                dueDay: clampedDueDay
            )
            newAccount.annualFeeAmount = resolvedAnnualFee
            newAccount.feeWaiverSpendTarget = resolvedFeeTarget
            newAccount.feeYearStartDate = resolvedFeeYearStart
            modelContext.insert(newAccount)
        }
        dismiss()
    }
}

#Preview {
    AddEditAccountView()
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
