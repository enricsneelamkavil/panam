//
//  EmailManagementView.swift
//  Panam
//

import SwiftUI
import SwiftData
import PDFKit

/// One level under ProfileView's "Email Management" card: two Dashboard-
/// style cards — Transaction Mails and Statement Mails — each opening
/// straight into its own complete configure → fetch → review flow in a
/// single sheet, nothing split across further screens.
struct EmailManagementView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showingTransactionMailsSheet = false
    @State private var showingStatementMailsSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingTransactionMailsSheet = true
                    } label: {
                        cardLabel(title: "Transaction Mails")
                    }
                    .buttonStyle(.plain)
                    .dashboardCard()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    Button {
                        showingStatementMailsSheet = true
                    } label: {
                        cardLabel(title: "Statement Mails")
                    }
                    .buttonStyle(.plain)
                    .dashboardCard()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationTitle("Email Management")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingTransactionMailsSheet) {
                TransactionMailsSheet()
            }
            .sheet(isPresented: $showingStatementMailsSheet) {
                StatementMailsSheet()
            }
        }
    }

    private func cardLabel(title: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Transaction Mails (configure → fetch → review, one sheet)

/// Everything for the transaction-alert email flow in one place, top to
/// bottom in order: sender-list configuration, the Fetch Emails CTA, then
/// the parsed-candidate review list — merges what used to be two separate
/// cards/sheets (Fetch Emails config + Import Emails review) into one.
private struct TransactionMailsSheet: View {
    @Environment(\.dismiss) private var dismiss
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
        NavigationStack {
            Form {
                Section {
                    ForEach(senderTerms, id: \.self) { term in
                        Text(term)
                    }
                    .onDelete(perform: removeSenderTerms)

                    HStack {
                        // The example deliberately isn't a real-shaped email
                        // address — iOS's data detector recognizes that
                        // pattern in placeholder text and renders it as a
                        // blue link regardless of .foregroundStyle (confirmed
                        // on-device). Breaking the @/.tld pattern sidesteps
                        // the detector entirely.
                        TextField("", text: $newSenderTerm, prompt: Text("e.g. alerts-at-hdfcbank-dot-net").foregroundStyle(.secondary))
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
                            Text("Fetch Emails")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appPrimary)
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
                        EmailCandidateRow(
                            candidate: candidate,
                            canImport: canQuickImport(candidate),
                            onEdit: { editingCandidate = candidate },
                            onImport: { quickImport(candidate) }
                        )
                    }
                }
            }
            .navigationTitle("Transaction Mails")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingCandidate) { candidate in
                AddEditTransactionView(prefill: candidate.parsed) {
                    GmailFetcher.markImported(candidate.gmailMessageID)
                    candidates.removeAll { $0.gmailMessageID == candidate.gmailMessageID }
                }
            }
        }
    }

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
private struct EmailCandidateRow: View {
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

// MARK: - Statement Mails (configure → fetch → review, one sheet)

/// Same shape as Transaction Mails: statement sender-list configuration,
/// a Fetch Emails CTA, then the reconciliation review list — all inline in
/// one sheet. This is a separate, simpler path from Settings → Import
/// Statement (StatementImportView): that one supports a manual file pick
/// and password-protected PDFs one at a time; this one is fully automatic
/// — it searches Gmail for every matching statement email, downloads and
/// reconciles each attachment, and aggregates the results. A locked PDF
/// found this way is reported, not silently dropped, with a pointer to
/// Settings → Import Statement to unlock and process it individually.
private struct StatementMailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Transaction.date) private var transactions: [Transaction]
    @Query(sort: \Account.name) private var accounts: [Account]

    @AppStorage(AppSettings.statementSenderTermsKey)
    private var statementSenderTermsRaw = AppSettings.statementSenderTermsDefault

    @State private var newStatementSenderTerm = ""
    @State private var isFetching = false
    @State private var fetchErrorMessage: String?
    @State private var matchedCount = 0
    @State private var totalCount = 0
    @State private var unmatched: [StatementReconciliationCandidate] = []
    @State private var editingCandidate: StatementReconciliationCandidate?

    private var statementSenderTerms: [String] {
        statementSenderTermsRaw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var hasFetched: Bool {
        totalCount > 0 || !unmatched.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(statementSenderTerms, id: \.self) { term in
                        Text(term)
                    }
                    .onDelete(perform: removeStatementSenderTerms)

                    HStack {
                        // See TransactionMailsSheet's matching TextField —
                        // same data-detector issue, same fix (a non-email-
                        // shaped example so iOS doesn't render part of it
                        // as a link).
                        TextField("", text: $newStatementSenderTerm, prompt: Text("e.g. estatements-at-hdfcbank-dot-net").foregroundStyle(.secondary))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Add", action: addStatementSenderTerm)
                            .disabled(newStatementSenderTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Search These Senders")
                } footer: {
                    Text("Panam searches Gmail for statement emails from any of these addresses/domains in the last 6 months.")
                }

                Section {
                    Button {
                        performFetch()
                    } label: {
                        if isFetching {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Fetch Emails")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appPrimary)
                    .disabled(isFetching || statementSenderTerms.isEmpty)

                    if let fetchErrorMessage {
                        Text(fetchErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if hasFetched {
                    Section {
                        LabeledContent("Matched") {
                            Text("\(matchedCount) of \(totalCount)")
                        }
                        if !unmatched.isEmpty {
                            LabeledContent("Possibly Missing") {
                                Text("\(unmatched.count)")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    if !unmatched.isEmpty {
                        Section {
                            ForEach(unmatched) { candidate in
                                StatementCandidateRow(
                                    candidate: candidate,
                                    canImport: canQuickImport(candidate),
                                    onEdit: { editingCandidate = candidate },
                                    onImport: { quickImport(candidate) }
                                )
                            }
                        } header: {
                            Text("Review")
                        } footer: {
                            Text("These statement lines didn't match any existing transaction by date, amount, and account.")
                        }
                    }
                }
            }
            .navigationTitle("Statement Mails")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingCandidate) { candidate in
                AddEditTransactionView(prefill: candidate.parsed) {
                    unmatched.removeAll { $0.id == candidate.id }
                }
            }
        }
    }

    private func addStatementSenderTerm() {
        let trimmed = newStatementSenderTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !statementSenderTerms.contains(trimmed) else { return }
        statementSenderTermsRaw += (statementSenderTermsRaw.isEmpty ? "" : "\n") + trimmed
        newStatementSenderTerm = ""
    }

    private func removeStatementSenderTerms(at offsets: IndexSet) {
        var terms = statementSenderTerms
        terms.remove(atOffsets: offsets)
        statementSenderTermsRaw = terms.joined(separator: "\n")
    }

    /// Searches Gmail for every matching statement email, downloads and
    /// reconciles each PDF attachment in turn, and aggregates matched
    /// counts / unmatched candidates across all of them. A password-
    /// protected or otherwise unreadable PDF is counted and reported in
    /// fetchErrorMessage rather than silently skipped — this flow has no
    /// per-file password prompt (see StatementImportView for that).
    private func performFetch() {
        isFetching = true
        fetchErrorMessage = nil
        matchedCount = 0
        totalCount = 0
        unmatched = []

        Task {
            do {
                let summaries = try await GmailFetcher.searchStatementEmails(senderTerms: statementSenderTerms)
                guard !summaries.isEmpty else {
                    isFetching = false
                    fetchErrorMessage = "No statement emails found for these senders in the last 6 months."
                    return
                }

                var aggregatedMatched = 0
                var aggregatedTotal = 0
                var aggregatedUnmatched: [StatementReconciliationCandidate] = []
                var lockedCount = 0
                var unreadableCount = 0

                for summary in summaries {
                    do {
                        let data = try await GmailFetcher.downloadAttachment(
                            messageID: summary.id, attachmentID: summary.attachmentID
                        )
                        guard let document = PDFDocument(data: data) else {
                            unreadableCount += 1
                            continue
                        }
                        guard !document.isLocked else {
                            lockedCount += 1
                            continue
                        }
                        let text = try StatementReconciler.extractText(from: document)
                        let entries = try await StatementReconciler.extractLineItems(from: text)
                        let result = StatementReconciler.reconcile(
                            entries: entries, against: transactions, accounts: accounts
                        )
                        aggregatedMatched += result.matchedCount
                        aggregatedTotal += entries.count
                        aggregatedUnmatched.append(contentsOf: result.unmatched)
                    } catch {
                        unreadableCount += 1
                    }
                }

                matchedCount = aggregatedMatched
                totalCount = aggregatedTotal
                unmatched = aggregatedUnmatched
                isFetching = false

                var notes: [String] = []
                if lockedCount > 0 {
                    notes.append("\(lockedCount) statement\(lockedCount == 1 ? "" : "s") password-protected — use Settings → Import Statement to unlock and process individually.")
                }
                if unreadableCount > 0 {
                    notes.append("\(unreadableCount) statement\(unreadableCount == 1 ? "" : "s") couldn't be read.")
                }
                fetchErrorMessage = notes.isEmpty ? nil : notes.joined(separator: " ")
            } catch {
                isFetching = false
                fetchErrorMessage = error.localizedDescription
            }
        }
    }

    /// Unlike Transaction Mails' quick-import (which requires both an
    /// account AND a category to resolve), a statement line never carries
    /// a category — StatementReconciler doesn't ask the model to guess one
    /// (see StatementLineItem). Requiring one here would make quick-import
    /// permanently unusable, so this only requires the account to resolve;
    /// the transaction is created uncategorized, same as StatementReconciliationView.
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

        unmatched.removeAll { $0.id == candidate.id }
    }
}

/// Same row shape as EmailCandidateRow, adapted for a statement line — no
/// parse-failure state (only the whole-email-batch fetch can fail, not an
/// individual reconciled line).
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
    EmailManagementView()
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
