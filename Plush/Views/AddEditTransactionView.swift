//
//  AddEditTransactionView.swift
//  Plush
//

import SwiftUI
import SwiftData

private struct SplitRow: Identifiable {
    var id = UUID()
    var person: Person? = nil
    var newPersonName: String = ""
    var amount: Double? = nil
}

struct AddEditTransactionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The transaction being edited, or nil when creating a new one.
    var transaction: Transaction?

    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \Category.name) private var categories: [Category]
    @Query(sort: \Person.name) private var people: [Person]

    @State private var type: TransactionType = .expense
    @State private var amount: Double?
    @State private var adjustmentIsPositive = true
    @State private var selectedAccount: Account?
    @State private var toAccount: Account?
    @State private var selectedCategory: Category?
    @State private var date: Date = .now
    @State private var note = ""
    @State private var merchantName = ""
    @State private var paymentMethod: PaymentMethod?
    @State private var upiApp = ""
    @State private var showingVoiceEntry = false
    @State private var isSplit = false
    @State private var myPortion: Double?
    @State private var splitRows: [SplitRow] = [SplitRow()]

    /// Types that carry a merchant name.
    private static let merchantEligibleTypes: Set<TransactionType> = [.expense, .refund, .taxAndFee]

    private static let inrFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    private var isEditing: Bool { transaction != nil }

    /// The single cash account, auto-assigned when Payment Method is Cash.
    private var cashAccount: Account? {
        accounts.first { $0.type == .cash }
    }

    /// Accounts compatible with the selected payment method.
    /// Transfers have no restriction — all accounts are valid on either side.
    private var filteredAccounts: [Account] {
        guard !type.isTransferLike else { return accounts }
        switch paymentMethod {
        case .cash:
            return accounts.filter { $0.type == .cash }
        case .upi:
            return accounts.filter {
                $0.type == .bank || ($0.type == .creditCard && $0.network == .rupay)
            }
        case .card:
            return accounts.filter { $0.type == .creditCard }
        case .netBanking:
            return accounts.filter { $0.type == .bank }
        case .wallet:
            return accounts.filter { $0.type == .wallet }
        case .other, nil:
            return accounts
        }
    }

    private var splitPortionSum: Double {
        (myPortion ?? 0) + splitRows.compactMap(\.amount).reduce(0, +)
    }

    private var canSave: Bool {
        guard let amount, amount > 0 else { return false }
        if type.isTransferLike {
            guard let from = selectedAccount, let to = toAccount else { return false }
            return from.persistentModelID != to.persistentModelID
        }
        if type == .adjustment {
            return selectedAccount != nil && !note.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return selectedAccount != nil && selectedCategory != nil
    }

    /// The signed amount actually applied to the account/stored on the transaction.
    /// Only .adjustment carries a sign; every other type stores a positive magnitude.
    private var signedAmount: Double? {
        guard let amount else { return nil }
        guard type == .adjustment else { return amount }
        return adjustmentIsPositive ? amount : -amount
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing {
                    Section {
                        Button {
                            showingVoiceEntry = true
                        } label: {
                            Label("Record with Voice", systemImage: "mic.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.appPrimary)
                    }
                }

                Section {
                    Picker("Type", selection: $type) {
                        ForEach(TransactionType.allCases, id: \.self) { transactionType in
                            Text(transactionType.displayName).tag(transactionType)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack {
                        TextField("Amount", value: $amount, format: .number)
                            .keyboardType(.decimalPad)

                        if type == .adjustment {
                            Picker("Sign", selection: $adjustmentIsPositive) {
                                Text("+").tag(true)
                                Text("−").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 90)
                        }
                    }
                }

                if !type.isTransferLike && type != .adjustment {
                    Section {
                        Picker("Payment Method", selection: $paymentMethod) {
                            Text("Not set").tag(nil as PaymentMethod?)
                            ForEach(PaymentMethod.allCases, id: \.self) { method in
                                Text(method.rawValue).tag(method as PaymentMethod?)
                            }
                        }

                        if paymentMethod == .upi {
                            TextField("UPI App", text: $upiApp)
                        }
                    }
                }

                Section {
                    if type.isTransferLike {
                        Picker("From", selection: $selectedAccount) {
                            Text("Select Account").tag(nil as Account?)
                            ForEach(accounts) { account in
                                Text(account.name).tag(account as Account?)
                            }
                        }
                        Picker("To", selection: $toAccount) {
                            Text("Select Account").tag(nil as Account?)
                            ForEach(accounts) { account in
                                Text(account.name).tag(account as Account?)
                            }
                        }
                        if let from = selectedAccount, let to = toAccount,
                           from.persistentModelID == to.persistentModelID {
                            Text("From and To must be different accounts.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        if paymentMethod == .cash {
                            // Cash auto-assigns to the single cash account — no picker shown.
                            if cashAccount == nil {
                                Text("No cash account found — add one in Accounts first")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Picker("Account", selection: $selectedAccount) {
                                Text("Select Account").tag(nil as Account?)
                                ForEach(filteredAccounts) { account in
                                    Text(account.name).tag(account as Account?)
                                }
                            }
                        }

                        if type != .adjustment {
                            Picker("Category", selection: $selectedCategory) {
                                Text("Select Category").tag(nil as Category?)
                                ForEach(categories) { category in
                                    Label(category.name, systemImage: category.icon)
                                        .tag(category as Category?)
                                }
                            }
                        }

                        if Self.merchantEligibleTypes.contains(type) {
                            TextField("Merchant", text: $merchantName)
                        }
                    }
                }

                // Split — expense only, creation only
                if type == .expense && !isEditing {
                    Section {
                        Toggle("Split with others", isOn: $isSplit)
                    }

                    if isSplit {
                        Section("Your Portion") {
                            TextField("Your share of the total", value: $myPortion, format: .number)
                                .keyboardType(.decimalPad)
                        }

                        ForEach($splitRows) { $row in
                            Section("Split with") {
                                Picker("Person", selection: $row.person) {
                                    Text("New Person").tag(nil as Person?)
                                    ForEach(people) { person in
                                        Text(person.name).tag(person as Person?)
                                    }
                                }
                                if row.person == nil {
                                    TextField("Name", text: $row.newPersonName)
                                }
                                TextField("Their share", value: $row.amount, format: .number)
                                    .keyboardType(.decimalPad)
                                if splitRows.count > 1 {
                                    Button("Remove", role: .destructive) {
                                        splitRows.removeAll { $0.id == row.id }
                                    }
                                }
                            }
                        }

                        Section {
                            Button("Add Another Person") {
                                splitRows.append(SplitRow())
                            }

                            if let total = amount, abs(total - splitPortionSum) > 0.01 {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text("Portions (\(splitPortionSum.formatted(Self.inrFormat))) don't add up to total (\(total.formatted(Self.inrFormat)))")
                                        .font(.caption)
                                }
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Section {
                    DatePicker("Date", selection: $date, displayedComponents: [.date])
                    TextField(type == .adjustment ? "Note (required)" : "Note (optional)", text: $note)
                }
            }
            .onChange(of: type) { _, newType in
                if newType.isTransferLike {
                    paymentMethod = nil
                    upiApp = ""
                    selectedCategory = nil
                } else {
                    toAccount = nil
                }
                if newType == .adjustment {
                    paymentMethod = nil
                    upiApp = ""
                    selectedCategory = nil
                    merchantName = ""
                }
                if newType != .expense {
                    isSplit = false
                    myPortion = nil
                    splitRows = [SplitRow()]
                }
            }
            .onChange(of: isSplit) { _, on in
                if !on {
                    myPortion = nil
                    splitRows = [SplitRow()]
                }
            }
            .onChange(of: paymentMethod) {
                guard !type.isTransferLike else { return }
                if paymentMethod != .upi {
                    upiApp = ""
                }
                if paymentMethod == .cash {
                    selectedAccount = cashAccount
                } else if let selectedAccount,
                          !filteredAccounts.contains(where: { $0 === selectedAccount }) {
                    self.selectedAccount = nil
                }
            }
            .navigationTitle(isEditing ? "Edit Transaction" : "New Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .tint(.appPrimary)
                }
            }
            .sheet(isPresented: $showingVoiceEntry) {
                VoiceEntrySheet { parsed in apply(parsed) }
            }
            .onAppear(perform: populateFromTransaction)
        }
    }

    /// Pre-fills the form from a voice-parsed result. Never saves — the user
    /// still reviews and taps Save exactly like manual entry.
    private func apply(_ parsed: ParsedTransaction) {
        amount = parsed.amount
        type = parsed.type.lowercased() == "income" ? .income : .expense
        date = parsed.resolvedDate

        if let methodName = parsed.paymentMethodName,
           let method = PaymentMethod.allCases.first(where: {
               $0.rawValue.compare(methodName, options: .caseInsensitive) == .orderedSame
           }) {
            paymentMethod = method
        }

        if let name = parsed.categoryName,
           let match = categories.first(where: {
               $0.name.compare(name, options: .caseInsensitive) == .orderedSame
           }) {
            selectedCategory = match
        }

        if paymentMethod == .cash {
            selectedAccount = cashAccount
        } else if let name = parsed.accountName,
                  let match = filteredAccounts.first(where: {
                      $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                  }) {
            selectedAccount = match
        }

        if let parsedNote = parsed.note, !parsedNote.isEmpty {
            note = parsedNote
        }
    }

    private func populateFromTransaction() {
        guard let transaction else { return }
        type = transaction.type
        if transaction.type == .adjustment {
            amount = abs(transaction.amount)
            adjustmentIsPositive = transaction.amount >= 0
        } else {
            amount = transaction.amount
        }
        selectedAccount = transaction.account
        selectedCategory = transaction.category
        date = transaction.date
        note = transaction.note
        merchantName = transaction.merchantName ?? ""
        paymentMethod = transaction.paymentMethod
        upiApp = transaction.upiApp ?? ""
        if transaction.type.isTransferLike {
            toAccount = transaction.toAccount
        }
        // Split configuration is creation-only; not editable after creation.
    }

    private func save() {
        guard let amount, amount > 0, let selectedAccount, let signedAmount else { return }
        let normalizedDate = Calendar.current.startOfDay(for: date)

        if let transaction {
            // Reverse the old transaction effect before applying new values.
            if transaction.type.isTransferLike {
                transaction.account?.reverseTransfer(
                    amount: transaction.amount,
                    to: transaction.toAccount
                )
            } else {
                transaction.account?.reverseTransaction(
                    amount: transaction.amount,
                    type: transaction.type
                )
            }

            transaction.amount = signedAmount
            transaction.type = type
            transaction.account = selectedAccount
            transaction.date = normalizedDate
            transaction.note = note

            if type.isTransferLike {
                transaction.toAccount = toAccount
                transaction.category = nil
                transaction.paymentMethod = nil
                transaction.upiApp = nil
                transaction.merchantName = nil
                selectedAccount.applyTransfer(amount: signedAmount, to: toAccount!)
                MoneyEventSync.sync(transaction: transaction, context: modelContext)
            } else if type == .adjustment {
                transaction.toAccount = nil
                transaction.category = nil
                transaction.paymentMethod = nil
                transaction.upiApp = nil
                transaction.merchantName = nil
                selectedAccount.applyTransaction(amount: signedAmount, type: type)
                MoneyEventSync.sync(transaction: transaction, context: modelContext)
            } else {
                transaction.toAccount = nil
                transaction.category = selectedCategory
                let trimmedUPIApp = upiApp.trimmingCharacters(in: .whitespaces)
                transaction.paymentMethod = paymentMethod
                transaction.upiApp = paymentMethod == .upi && !trimmedUPIApp.isEmpty ? trimmedUPIApp : nil
                transaction.merchantName = merchantNameToStore
                selectedAccount.applyTransaction(amount: signedAmount, type: type)
                MoneyEventSync.sync(transaction: transaction, context: modelContext)
            }
        } else {
            let newTransaction = Transaction(
                amount: signedAmount,
                date: normalizedDate,
                note: note,
                type: type,
                account: selectedAccount,
                category: (type.isTransferLike || type == .adjustment) ? nil : selectedCategory
            )

            if type.isTransferLike {
                newTransaction.toAccount = toAccount
                modelContext.insert(newTransaction)
                selectedAccount.applyTransfer(amount: signedAmount, to: toAccount!)
                MoneyEventSync.sync(transaction: newTransaction, context: modelContext)
            } else if type == .adjustment {
                modelContext.insert(newTransaction)
                selectedAccount.applyTransaction(amount: signedAmount, type: type)
                MoneyEventSync.sync(transaction: newTransaction, context: modelContext)
            } else {
                let trimmedUPIApp = upiApp.trimmingCharacters(in: .whitespaces)
                newTransaction.paymentMethod = paymentMethod
                newTransaction.upiApp = paymentMethod == .upi && !trimmedUPIApp.isEmpty ? trimmedUPIApp : nil
                newTransaction.merchantName = merchantNameToStore

                if isSplit {
                    newTransaction.isSplit = true
                    newTransaction.myPortionAmount = myPortion
                }

                modelContext.insert(newTransaction)
                selectedAccount.applyTransaction(amount: signedAmount, type: type)
                MoneyEventSync.sync(transaction: newTransaction, context: modelContext)

                if isSplit {
                    createSplitAllocations(for: newTransaction, date: normalizedDate)
                }
            }
        }
        dismiss()
    }

    /// Trimmed merchant name for types that carry one, else nil.
    private var merchantNameToStore: String? {
        guard Self.merchantEligibleTypes.contains(type) else { return nil }
        let trimmed = merchantName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func createSplitAllocations(for transaction: Transaction, date: Date) {
        let baseNote: String = {
            let cat = selectedCategory?.name ?? ""
            if !note.isEmpty { return "Split: \(note)" }
            if !cat.isEmpty { return "Split: \(cat)" }
            return "Split expense"
        }()

        for row in splitRows {
            guard let rowAmount = row.amount, rowAmount > 0 else { continue }

            let entryPerson: Person
            if let existing = row.person {
                entryPerson = existing
            } else {
                let trimmed = row.newPersonName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let newPerson = Person(name: trimmed)
                modelContext.insert(newPerson)
                entryPerson = newPerson
            }

            let allocation = SplitAllocation(
                amount: rowAmount,
                person: entryPerson,
                transaction: transaction
            )
            modelContext.insert(allocation)

            // Lending entry records what this person owes you.
            // No balance adjustment — money already moved via the parent transaction.
            let entry = LendingEntry(
                amount: rowAmount,
                date: date,
                note: baseNote,
                kind: .lent,
                person: entryPerson
            )
            entry.sourceTransaction = transaction
            modelContext.insert(entry)
            allocation.lendingEntry = entry
        }
    }
}

#Preview {
    AddEditTransactionView()
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
