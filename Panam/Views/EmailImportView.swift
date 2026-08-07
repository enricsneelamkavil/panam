//
//  EmailImportView.swift
//  Panam
//

import SwiftUI
import SwiftData

/// Connect/disconnect Gmail, configure which senders to search, fetch and
/// parse candidate transaction emails, then review and import them.
struct EmailImportView: View {
    @Environment(GmailAuthManager.self) private var gmailAuth
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \Category.name) private var categories: [Category]

    @AppStorage(AppSettings.gmailSenderTermsKey)
    private var senderTermsRaw = AppSettings.gmailSenderTermsDefault

    @State private var newSenderTerm = ""
    @State private var candidates: [EmailTransactionCandidate] = []
    @State private var isFetching = false
    @State private var fetchErrorMessage: String?
    @State private var editingCandidate: EmailTransactionCandidate?

    private var senderTerms: [String] {
        senderTermsRaw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            Section {
                if let email = gmailAuth.signedInEmail {
                    Label("Connected as \(email)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Button("Disconnect", role: .destructive) {
                        gmailAuth.signOut()
                        candidates = []
                    }
                } else {
                    Button("Connect Gmail") {
                        gmailAuth.signIn()
                    }
                }
            } footer: {
                Text("Connect a Gmail account so Panam can read transaction emails. Nothing is imported without your review.")
            }

            if gmailAuth.signedInEmail != nil {
                Section {
                    ForEach(senderTerms, id: \.self) { term in
                        Text(term)
                    }
                    .onDelete(perform: removeSenderTerms)

                    HStack {
                        TextField("e.g. alerts@hdfcbank.net", text: $newSenderTerm)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Add", action: addSenderTerm)
                            .disabled(newSenderTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Search These Senders")
                } footer: {
                    Text("Panam searches Gmail for messages from any of these addresses/domains in the last 30 days.")
                }

                Section {
                    Button {
                        performFetch()
                    } label: {
                        if isFetching {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Fetch New Emails")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                    .disabled(isFetching || senderTerms.isEmpty)

                    if let fetchErrorMessage {
                        Text(fetchErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !candidates.isEmpty {
                    Section {
                        Button("Import All") {
                            importAll()
                        }
                        .disabled(!candidates.contains(where: canQuickImport))
                    } header: {
                        Text("Review (\(candidates.count))")
                    }

                    ForEach(candidates) { candidate in
                        CandidateRow(
                            candidate: candidate,
                            canImport: canQuickImport(candidate),
                            onEdit: { editingCandidate = candidate },
                            onImport: { quickImport(candidate) }
                        )
                    }
                }
            }
        }
        .navigationTitle("Email Import")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingCandidate) { candidate in
            AddEditTransactionView(prefill: candidate.parsed) {
                GmailFetcher.markImported(candidate.gmailMessageID)
                candidates.removeAll { $0.gmailMessageID == candidate.gmailMessageID }
            }
        }
    }

    // MARK: - Sender terms

    private func addSenderTerm() {
        let trimmed = newSenderTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !senderTerms.contains(trimmed) else { return }
        senderTermsRaw += (senderTermsRaw.isEmpty ? "" : "\n") + trimmed
        newSenderTerm = ""
    }

    private func removeSenderTerms(at offsets: IndexSet) {
        var terms = senderTerms
        terms.remove(atOffsets: offsets)
        senderTermsRaw = terms.joined(separator: "\n")
    }

    // MARK: - Fetch + parse

    private func performFetch() {
        isFetching = true
        fetchErrorMessage = nil
        Task {
            do {
                let messages = try await GmailFetcher.fetchCandidateMessages(senderTerms: senderTerms)
                var results: [EmailTransactionCandidate] = []
                for message in messages {
                    do {
                        let parsed = try await EmailTransactionParser.parse(
                            emailBody: message.bodyText,
                            subject: message.subject,
                            categories: categories,
                            accounts: accounts
                        )
                        results.append(EmailTransactionCandidate(
                            gmailMessageID: message.id,
                            rawSubject: message.subject,
                            rawSnippet: message.snippet,
                            parsed: parsed,
                            parseError: nil
                        ))
                    } catch {
                        results.append(EmailTransactionCandidate(
                            gmailMessageID: message.id,
                            rawSubject: message.subject,
                            rawSnippet: message.snippet,
                            parsed: nil,
                            parseError: error.localizedDescription
                        ))
                    }
                }
                candidates = results
                isFetching = false
            } catch {
                fetchErrorMessage = error.localizedDescription
                isFetching = false
            }
        }
    }

    // MARK: - Import

    /// A last-4-digits match (from the email body) is unambiguous where a
    /// name/merchant guess isn't — it takes priority, same as
    /// AddEditTransactionView's apply(_:). If it's present but matches no
    /// account, we deliberately don't fall back to the name-based guess.
    private func resolveAccount(_ parsed: ParsedTransaction) -> Account? {
        let trimmedLastFour = parsed.lastFourDigits?.trimmingCharacters(in: .whitespaces) ?? ""
        if !trimmedLastFour.isEmpty {
            return accounts.first { $0.lastFourDigits == trimmedLastFour }
        }
        guard let name = parsed.accountName else { return nil }
        return accounts.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    private func resolveCategory(_ name: String?) -> Category? {
        guard let name else { return nil }
        return categories.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    private func resolvePaymentMethod(_ name: String?) -> PaymentMethod? {
        guard let name else { return nil }
        return PaymentMethod.allCases.first { $0.rawValue.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// A candidate can be imported with one tap only if it parsed cleanly
    /// AND its account/category names resolved to real records — otherwise
    /// it needs a trip through Edit first.
    private func canQuickImport(_ candidate: EmailTransactionCandidate) -> Bool {
        guard let parsed = candidate.parsed, parsed.amount > 0 else { return false }
        return resolveAccount(parsed) != nil && resolveCategory(parsed.categoryName) != nil
    }

    private func quickImport(_ candidate: EmailTransactionCandidate) {
        guard let parsed = candidate.parsed,
              let account = resolveAccount(parsed),
              let category = resolveCategory(parsed.categoryName) else { return }

        let type: TransactionType = parsed.type.lowercased() == "income" ? .income : .expense
        let transaction = Transaction(
            amount: parsed.amount,
            date: parsed.resolvedDate,
            note: parsed.note ?? "",
            type: type,
            account: account,
            category: category
        )
        if type == .expense {
            let trimmedMerchant = parsed.merchantName?.trimmingCharacters(in: .whitespaces) ?? ""
            transaction.merchantName = trimmedMerchant.isEmpty ? nil : trimmedMerchant
        }
        transaction.paymentMethod = resolvePaymentMethod(parsed.paymentMethodName)

        modelContext.insert(transaction)
        account.applyTransaction(amount: parsed.amount, type: type)
        MoneyEventSync.sync(transaction: transaction, context: modelContext)

        GmailFetcher.markImported(candidate.gmailMessageID)
        candidates.removeAll { $0.gmailMessageID == candidate.gmailMessageID }
    }

    private func importAll() {
        for candidate in candidates.filter(canQuickImport) {
            quickImport(candidate)
        }
    }
}

/// A single review row: parsed amount/merchant/date (or the raw subject and
/// parse error, if parsing failed), plus Edit and Import actions.
private struct CandidateRow: View {
    let candidate: EmailTransactionCandidate
    let canImport: Bool
    let onEdit: () -> Void
    let onImport: () -> Void

    private static let inrFormat = FloatingPointFormatStyle<Double>.Currency
        .currency(code: "INR")
        .locale(Locale(identifier: "en_IN"))

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let parsed = candidate.parsed {
                HStack {
                    Text(parsed.amount, format: Self.inrFormat)
                        .font(.headline)
                    Spacer()
                    Text(parsed.resolvedDate, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(merchantOrSubjectText(parsed))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(candidate.rawSubject)
                    .font(.subheadline)
                if let parseError = candidate.parseError {
                    Text(parseError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

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

    private func merchantOrSubjectText(_ parsed: ParsedTransaction) -> String {
        if let merchant = parsed.merchantName, !merchant.isEmpty { return merchant }
        return candidate.rawSubject
    }
}

#Preview {
    NavigationStack {
        EmailImportView()
            .environment(GmailAuthManager())
            .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
    }
}
