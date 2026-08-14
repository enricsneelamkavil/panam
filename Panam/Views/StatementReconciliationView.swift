//
//  StatementReconciliationView.swift
//  Panam
//

import SwiftUI
import SwiftData

/// Shows how a statement reconciled against what's already logged in Panam
/// — a matched-count confidence signal up top ("47 of 50 matched" reads
/// very differently than an unexplained list with no context), then the
/// same review-row/Edit/Import pattern as EmailImportView's candidate list
/// for everything that didn't match: "you may have forgotten to log this."
struct StatementReconciliationView: View {
    let matchedCount: Int
    let totalCount: Int
    let unmatched: [StatementReconciliationCandidate]

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var importedIDs: Set<UUID> = []
    @State private var editingCandidate: StatementReconciliationCandidate?

    private var remaining: [StatementReconciliationCandidate] {
        unmatched.filter { !importedIDs.contains($0.id) }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Matched") {
                    Text("\(matchedCount) of \(totalCount)")
                }
                if !unmatched.isEmpty {
                    LabeledContent("Possibly Missing") {
                        Text("\(remaining.count)")
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text(unmatched.isEmpty
                     ? "Every line on this statement matches a transaction already logged in Panam."
                     : "These statement lines didn't match any existing transaction by date, amount, and account — review each one before deciding whether to log it.")
            }

            if !remaining.isEmpty {
                Section {
                    ForEach(remaining) { candidate in
                        StatementCandidateRow(
                            candidate: candidate,
                            canImport: canQuickImport(candidate),
                            onEdit: { editingCandidate = candidate },
                            onImport: { quickImport(candidate) }
                        )
                    }
                } header: {
                    Text("Review")
                }
            }
        }
        .navigationTitle("Statement Reconciliation")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingCandidate) { candidate in
            AddEditTransactionView(prefill: candidate.parsed) {
                importedIDs.insert(candidate.id)
            }
        }
    }

    /// Unlike email import's quick-import (which requires both an account
    /// AND a category to resolve before allowing a one-tap add), a
    /// statement line never carries a category — StatementReconciler
    /// deliberately doesn't ask the model to guess one, since a statement
    /// rarely states one (see StatementLineItem). Requiring one here would
    /// make quick-import permanently unusable, so this only requires the
    /// account to resolve; the transaction is created uncategorized, same
    /// as any manually-entered one left that way.
    private func resolveAccount(_ parsed: ParsedTransaction) -> Account? {
        let trimmed = parsed.lastFourDigits?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return accounts.first { $0.lastFourDigits == trimmed }
    }

    private func canQuickImport(_ candidate: StatementReconciliationCandidate) -> Bool {
        candidate.parsed.amount > 0 && resolveAccount(candidate.parsed) != nil
    }

    private func quickImport(_ candidate: StatementReconciliationCandidate) {
        let parsed = candidate.parsed
        guard let account = resolveAccount(parsed) else { return }

        let transaction = Transaction(
            amount: parsed.amount,
            date: parsed.resolvedDate,
            note: parsed.note ?? "",
            type: .expense,
            account: account,
            category: nil
        )
        let trimmedMerchant = parsed.merchantName?.trimmingCharacters(in: .whitespaces) ?? ""
        transaction.merchantName = trimmedMerchant.isEmpty ? nil : trimmedMerchant

        modelContext.insert(transaction)
        account.applyTransaction(amount: parsed.amount, type: .expense)
        MoneyEventSync.sync(transaction: transaction, context: modelContext)

        importedIDs.insert(candidate.id)
    }
}

/// Same row shape as EmailImportView's CandidateRow, adapted for a
/// statement line — no parse-failure state here, since a single statement
/// line never fails extraction independently (only the whole-statement
/// model call can fail, which StatementImportView surfaces before this
/// view is ever reached).
private struct StatementCandidateRow: View {
    let candidate: StatementReconciliationCandidate
    let canImport: Bool
    let onEdit: () -> Void
    let onImport: () -> Void

    private static let inrFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.parsed.amount, format: Self.inrFormat)
                    .font(.headline)
                Spacer()
                Text(candidate.parsed.resolvedDate, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(candidate.rawDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack {
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Import", action: onImport)
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                    .disabled(!canImport)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        StatementReconciliationView(matchedCount: 47, totalCount: 50, unmatched: [])
    }
    .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
