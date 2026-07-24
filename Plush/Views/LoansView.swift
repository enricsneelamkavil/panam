import SwiftUI
import SwiftData

struct LoansView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Loan.name) private var loans: [Loan]

    @State private var showingAddSheet = false

    var body: some View {
        List {
            ForEach(loans) { loan in
                NavigationLink {
                    LoanDetailView(loan: loan)
                } label: {
                    LoanRow(loan: loan)
                }
            }
            .onDelete(perform: deleteLoans)
        }
        .overlay {
            if loans.isEmpty {
                ContentUnavailableView(
                    "No Loans",
                    systemImage: "banknote",
                    description: Text("Tap + to start tracking a loan.")
                )
            }
        }
        .navigationTitle("Loans")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAddSheet = true } label: {
                    Label("Add Loan", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddLoanView()
        }
    }

    private func deleteLoans(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(loans[index])
        }
    }
}

private struct LoanRow: View {
    let loan: Loan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(loan.name)
                    .font(.body)
                if !loan.isActive {
                    Text("Closed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemGray5), in: Capsule())
                }
                Spacer()
                MaskableCurrencyText(amount: loan.remainingAmount)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(loan.paidCount == loan.tenureMonths ? .secondary : .primary)
            }
            Text("\(loan.paidCount)/\(loan.tenureMonths) paid · \(loan.emiAmount.formatted(.currency(code: "INR").locale(Locale(identifier: "en_IN"))))/mo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AddLoanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var name = ""
    @State private var principalAmount: Double?
    @State private var interestRate: Double?
    @State private var emiAmount: Double?
    @State private var tenureMonths: Int?
    @State private var startDate: Date = .now
    @State private var selectedAccount: Account?

    private var eligibleAccounts: [Account] {
        accounts.filter { $0.type != .creditCard }
    }

    private var canSave: Bool {
        guard let principal = principalAmount, principal > 0,
              let emi = emiAmount, emi > 0,
              let tenure = tenureMonths, tenure >= 1
        else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Loan Name") {
                    TextField("e.g. Personal Loan – HDFC", text: $name)
                }

                Section("Details") {
                    TextField("Principal Amount", value: $principalAmount, format: .number)
                        .keyboardType(.decimalPad)

                    TextField("Interest Rate (% p.a., optional)", value: $interestRate, format: .number)
                        .keyboardType(.decimalPad)

                    TextField("EMI Amount", value: $emiAmount, format: .number)
                        .keyboardType(.decimalPad)

                    TextField("Tenure (months)", value: $tenureMonths, format: .number)
                        .keyboardType(.numberPad)

                    DatePicker("First EMI Date", selection: $startDate, displayedComponents: .date)
                }

                Section("Debit Account") {
                    Picker("Account", selection: $selectedAccount) {
                        Text("None").tag(nil as Account?)
                        ForEach(eligibleAccounts) { account in
                            Text(account.name).tag(account as Account?)
                        }
                    }
                }
            }
            .navigationTitle("New Loan")
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
        }
    }

    private func save() {
        guard let principal = principalAmount, principal > 0,
              let emi = emiAmount, emi > 0,
              let tenure = tenureMonths, tenure >= 1
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let loan = Loan(
            name: trimmed,
            principalAmount: principal,
            interestRate: interestRate,
            emiAmount: emi,
            tenureMonths: tenure,
            startDate: startDate,
            account: selectedAccount
        )
        modelContext.insert(loan)
        LoanInstallmentGenerator.generateInstallments(for: loan, context: modelContext)
        dismiss()
    }
}
