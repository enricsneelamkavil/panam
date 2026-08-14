//
//  AddEditTransactionView.swift
//  Panam
//

import SwiftUI
import SwiftData

private struct SplitRow: Identifiable {
    var id = UUID()
    var person: Person? = nil
    var newPersonName: String = ""
    var amount: Double? = nil
    /// True once the user has typed a value directly into this row — excludes
    /// it from auto-redistribution in "Split by Amount" mode.
    var isLocked: Bool = false
}

private enum SplitMode: String, CaseIterable {
    case equal = "Split Equally"
    case byAmount = "Split by Amount"
}

struct AddEditTransactionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The transaction being edited, or nil when creating a new one.
    var transaction: Transaction?

    /// Pre-fills a new transaction (e.g. from email import review) — ignored when editing.
    var prefill: ParsedTransaction?

    /// Called right after a successful save, before dismissal — lets callers
    /// (e.g. email import) react without this view knowing about them.
    var onSaved: (() -> Void)?

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
    @State private var showingReceiptScan = false
    @State private var isSplit = false
    @State private var paidForSomeoneElse = false
    @State private var myPortion: Double?
    @State private var myPortionLocked = false
    @State private var splitRows: [SplitRow] = [SplitRow()]
    @State private var splitMode: SplitMode = .equal
    @State private var paidBySomeoneElse = false
    @State private var paidByPersonSelected: Person?
    @State private var paidByNewPersonName = ""

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

    /// A binding for "Your Portion" that locks it as soon as the user types
    /// into it, then redistributes the remainder across the still-unlocked rows.
    private var myPortionBinding: Binding<Double?> {
        Binding(
            get: { myPortion },
            set: { newValue in
                myPortion = newValue
                myPortionLocked = true
                redistributeRemainder()
            }
        )
    }

    /// A binding for a split row's amount that locks that row as soon as the
    /// user types into it, then redistributes the remainder across the rest.
    private func lockingBinding(for row: Binding<SplitRow>) -> Binding<Double?> {
        Binding(
            get: { row.wrappedValue.amount },
            set: { newValue in
                row.wrappedValue.amount = newValue
                row.wrappedValue.isLocked = true
                redistributeRemainder()
            }
        )
    }

    private func rounded2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// Divides the total evenly across every participant (you + each row),
    /// giving any rounding remainder to the last participant so the sum matches exactly.
    private func recalcEqualSplit() {
        guard let total = amount, total > 0 else { return }
        let count = splitRows.count + 1
        let each = rounded2(total / Double(count))
        myPortion = each
        for i in splitRows.indices {
            splitRows[i].amount = each
        }
        let remainder = rounded2(total - each * Double(count))
        if remainder != 0 {
            if splitRows.isEmpty {
                myPortion = (myPortion ?? 0) + remainder
            } else {
                let lastIndex = splitRows.count - 1
                splitRows[lastIndex].amount = (splitRows[lastIndex].amount ?? 0) + remainder
            }
        }
    }

    /// Google-Pay-style auto-fill: whatever remains after locked (manually-typed)
    /// portions is split evenly across every still-unlocked participant.
    private func redistributeRemainder() {
        guard let total = amount else { return }
        let lockedSum = (myPortionLocked ? (myPortion ?? 0) : 0)
            + splitRows.filter(\.isLocked).compactMap(\.amount).reduce(0, +)
        let unlockedIndices = splitRows.indices.filter { !splitRows[$0].isLocked }
        let myPortionUnlocked = !myPortionLocked
        let unlockedCount = unlockedIndices.count + (myPortionUnlocked ? 1 : 0)
        guard unlockedCount > 0 else { return }

        let remainder = total - lockedSum
        let each = rounded2(remainder / Double(unlockedCount))

        if myPortionUnlocked { myPortion = each }
        for i in unlockedIndices { splitRows[i].amount = each }

        // Give any rounding remainder to the last unlocked participant.
        let diff = rounded2(remainder - each * Double(unlockedCount))
        if diff != 0 {
            if let lastRowIndex = unlockedIndices.last {
                splitRows[lastRowIndex].amount = (splitRows[lastRowIndex].amount ?? 0) + diff
            } else if myPortionUnlocked {
                myPortion = (myPortion ?? 0) + diff
            }
        }
    }

    private func recalcCurrentSplit() {
        if splitMode == .equal {
            recalcEqualSplit()
        } else {
            redistributeRemainder()
        }
    }

    /// "Paid entirely for someone else": your portion is forced to ₹0 and the
    /// full total is assigned to a single split-with person — collapses the
    /// row list down to exactly one row and locks both sides of the split.
    private func applyPaidForSomeoneElse() {
        myPortion = 0
        myPortionLocked = true
        if splitRows.count > 1 { splitRows = [splitRows[0]] }
        if splitRows.isEmpty { splitRows = [SplitRow()] }
        splitRows[0].amount = amount
        splitRows[0].isLocked = true
    }

    /// True when the "Someone else paid for this" toggle applies — expense-only,
    /// creation-only (mirrors Split). No account is involved; the payer is
    /// tracked via `paidByPerson` and a linked borrowed LendingEntry instead.
    private var isPaidBySomeoneElse: Bool {
        type == .expense && !isEditing && paidBySomeoneElse
    }

    /// True once a payer has been chosen or a new payer's name typed.
    private var paidByPersonReady: Bool {
        paidByPersonSelected != nil || !paidByNewPersonName.trimmingCharacters(in: .whitespaces).isEmpty
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
        if isPaidBySomeoneElse {
            return selectedCategory != nil && paidByPersonReady
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
                    HStack(spacing: 12) {
                        Button {
                            showingVoiceEntry = true
                        } label: {
                            // A plain HStack instead of Label(_:systemImage:):
                            // .lineLimit/.minimumScaleFactor are Text-specific
                            // modifiers — applied to a whole Label they were
                            // shrinking/dropping the icon glyph entirely
                            // (confirmed on-device) while the text merely
                            // truncated instead of scaling. Scoping them to
                            // just the Text leaves the icon untouched.
                            HStack(spacing: 6) {
                                Image(systemName: "mic.fill")
                                Text("Record with Voice")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.appPrimary)

                        Button {
                            showingReceiptScan = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "camera.viewfinder")
                                Text("Scan Receipt")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.appPrimary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
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

                // "Someone else paid" — expense only, creation only
                if type == .expense && !isEditing {
                    Section {
                        Toggle("Someone else paid for this", isOn: $paidBySomeoneElse)
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
                        if isPaidBySomeoneElse {
                            // No account is involved — someone else's money paid for this.
                            Picker("Paid By", selection: $paidByPersonSelected) {
                                Text("New Person").tag(nil as Person?)
                                ForEach(people) { person in
                                    Text(person.name).tag(person as Person?)
                                }
                            }
                            if paidByPersonSelected == nil {
                                TextField("Name", text: $paidByNewPersonName)
                            }
                        } else if paymentMethod == .cash {
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
                if type == .expense && !isEditing && !paidBySomeoneElse {
                    Section {
                        Toggle("Split with others", isOn: $isSplit)
                    }

                    if isSplit {
                        Section {
                            Toggle("Paid entirely for someone else", isOn: $paidForSomeoneElse)
                        }

                        if !paidForSomeoneElse {
                            Section {
                                Picker("Split Mode", selection: $splitMode) {
                                    ForEach(SplitMode.allCases, id: \.self) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            Section("Your Portion") {
                                if splitMode == .equal {
                                    LabeledContent("Your share") {
                                        Text(myPortion ?? 0, format: Self.inrFormat)
                                    }
                                } else {
                                    TextField("Your share of the total", value: myPortionBinding, format: .number)
                                        .keyboardType(.decimalPad)
                                }
                            }
                        }

                        ForEach($splitRows) { $row in
                            Section(paidForSomeoneElse ? "Paid For" : "Split with") {
                                Picker("Person", selection: $row.person) {
                                    Text("New Person").tag(nil as Person?)
                                    ForEach(people) { person in
                                        Text(person.name).tag(person as Person?)
                                    }
                                }
                                if row.person == nil {
                                    TextField("Name", text: $row.newPersonName)
                                }
                                if !paidForSomeoneElse {
                                    if splitMode == .equal {
                                        LabeledContent("Their share") {
                                            Text(row.amount ?? 0, format: Self.inrFormat)
                                        }
                                    } else {
                                        TextField("Their share", value: lockingBinding(for: $row), format: .number)
                                            .keyboardType(.decimalPad)
                                    }
                                    if splitRows.count > 1 {
                                        Button("Remove", role: .destructive) {
                                            splitRows.removeAll { $0.id == row.id }
                                            recalcCurrentSplit()
                                        }
                                    }
                                }
                            }
                        }

                        if !paidForSomeoneElse {
                            Section {
                                Button("Add Another Person") {
                                    splitRows.append(SplitRow())
                                    recalcCurrentSplit()
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
                    paidForSomeoneElse = false
                    myPortion = nil
                    splitRows = [SplitRow()]
                    paidBySomeoneElse = false
                    paidByPersonSelected = nil
                    paidByNewPersonName = ""
                }
            }
            .onChange(of: isSplit) { _, on in
                if !on {
                    myPortion = nil
                    myPortionLocked = false
                    splitRows = [SplitRow()]
                    splitMode = .equal
                    paidForSomeoneElse = false
                } else {
                    myPortionLocked = false
                    splitMode = .equal
                    paidBySomeoneElse = false
                    for i in splitRows.indices { splitRows[i].isLocked = false }
                    recalcEqualSplit()
                }
            }
            .onChange(of: paidForSomeoneElse) { _, on in
                if on {
                    applyPaidForSomeoneElse()
                } else {
                    myPortionLocked = false
                    for i in splitRows.indices { splitRows[i].isLocked = false }
                    recalcCurrentSplit()
                }
            }
            .onChange(of: splitMode) { _, newMode in
                myPortionLocked = false
                for i in splitRows.indices { splitRows[i].isLocked = false }
                if newMode == .equal {
                    recalcEqualSplit()
                } else {
                    redistributeRemainder()
                }
            }
            .onChange(of: amount) { _, _ in
                guard isSplit else { return }
                if paidForSomeoneElse {
                    applyPaidForSomeoneElse()
                } else {
                    recalcCurrentSplit()
                }
            }
            .onChange(of: paidBySomeoneElse) { _, on in
                if on {
                    isSplit = false
                } else {
                    paidByPersonSelected = nil
                    paidByNewPersonName = ""
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
                        .buttonStyle(.borderedProminent)
                        .tint(.appPrimary)
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingVoiceEntry) {
                VoiceEntrySheet { parsed in apply(parsed) }
            }
            .sheet(isPresented: $showingReceiptScan) {
                ReceiptScanSheet { parsed in apply(parsed) }
            }
            .onAppear(perform: populateFromTransaction)
        }
    }

    /// Pre-fills the form from a parsed result — voice, receipt scan, or
    /// email import all funnel through the same ParsedTransaction shape.
    /// Never saves — the user still reviews and taps Save exactly like
    /// manual entry.
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

        // A last-4-digits match (from an email alert) is unambiguous where a
        // name/merchant guess isn't — it takes priority, and if it's present
        // but matches nothing, we deliberately leave the account unselected
        // rather than fall back to guessing by name.
        let trimmedLastFour = parsed.lastFourDigits?.trimmingCharacters(in: .whitespaces) ?? ""
        if !trimmedLastFour.isEmpty {
            if let match = accounts.first(where: { $0.lastFourDigits == trimmedLastFour }) {
                selectedAccount = match
            }
        } else if paymentMethod == .cash {
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

        if let parsedMerchant = parsed.merchantName, !parsedMerchant.isEmpty {
            merchantName = parsedMerchant
        }
    }

    private func populateFromTransaction() {
        guard let transaction else {
            if let prefill { apply(prefill) }
            return
        }
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

    /// Resolves the "Paid By" person for the "Someone else paid for this"
    /// flow, creating and inserting a new Person if a name was typed instead
    /// of an existing one being picked.
    private func resolvePaidByPerson() -> Person? {
        if let paidByPersonSelected { return paidByPersonSelected }
        let trimmed = paidByNewPersonName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let newPerson = Person(name: trimmed)
        modelContext.insert(newPerson)
        return newPerson
    }

    private func save() {
        guard let amount, amount > 0, let signedAmount else { return }
        guard isPaidBySomeoneElse || selectedAccount != nil else { return }
        let normalizedDate = Calendar.current.startOfDay(for: date)

        if let transaction {
            guard let selectedAccount else { return }
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
        } else if isPaidBySomeoneElse {
            guard let payer = resolvePaidByPerson() else { return }

            let newTransaction = Transaction(
                amount: signedAmount,
                date: normalizedDate,
                note: note,
                type: type,
                account: nil,
                category: selectedCategory
            )
            let trimmedUPIApp = upiApp.trimmingCharacters(in: .whitespaces)
            newTransaction.paymentMethod = paymentMethod
            newTransaction.upiApp = paymentMethod == .upi && !trimmedUPIApp.isEmpty ? trimmedUPIApp : nil
            newTransaction.merchantName = merchantNameToStore
            newTransaction.paidByPerson = payer

            modelContext.insert(newTransaction)
            // No applyTransaction call — no account moved, so no balance to update.
            MoneyEventSync.sync(transaction: newTransaction, context: modelContext)

            let entryNote: String = {
                let cat = selectedCategory?.name ?? ""
                if !note.isEmpty { return note }
                if !cat.isEmpty { return cat }
                return "Paid for you"
            }()
            let entry = LendingEntry(
                amount: amount,
                date: normalizedDate,
                note: entryNote,
                kind: .borrowed,
                person: payer
            )
            entry.sourceTransaction = newTransaction
            modelContext.insert(entry)

            onSaved?()
            dismiss()
            return
        } else {
            guard let selectedAccount else { return }
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
        onSaved?()
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
