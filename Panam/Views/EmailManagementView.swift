//
//  EmailManagementView.swift
//  Panam
//

import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

/// One level under ProfileView's "Email Management" card: two Dashboard-
/// style cards — Transaction Mails and Statement Mails — each opening
/// straight into its own complete configure → fetch → review flow in a
/// single sheet, nothing split across further screens.
struct EmailManagementView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showingTransactionMailsSheet = false
    @State private var showingStatementMailsSheet = false
    /// Captured once on appear (and the store cleared right after) so these
    /// show exactly once — ProfileView's badge count is what tells you
    /// there's something new here in the first place.
    @State private var autoFetchNotices: [StatementAutoFetchNotice] = []

    var body: some View {
        NavigationStack {
            Form {
                if !autoFetchNotices.isEmpty {
                    Section {
                        ForEach(autoFetchNotices) { notice in
                            AutoFetchNoticeRow(notice: notice)
                        }
                    } header: {
                        Text("Automatic Statement Checks")
                    } footer: {
                        Text("Panam checked these cards' statement email automatically based on each card's Statement Email Day.")
                    }
                }

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
            .onAppear {
                autoFetchNotices = StatementAutoFetchStore.notices
                StatementAutoFetchStore.clearNotices()
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

/// One automatic-check outcome — same shape/vocabulary as Statement Mails'
/// own "Matched X of Y" summary, so a checked-for-you result reads exactly
/// like a manual fetch would have.
private struct AutoFetchNoticeRow: View {
    let notice: StatementAutoFetchNotice

    private static let dateFormat = Date.FormatStyle(date: .abbreviated, time: .omitted)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(notice.accountName)
                    .font(.subheadline)
                Spacer()
                Text(notice.checkedAt.formatted(Self.dateFormat))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Matched \(notice.matchedCount) of \(notice.totalCount)" + (notice.unmatchedCount > 0 ? " — \(notice.unmatchedCount) possibly missing" : ""))
                .font(.caption)
                .foregroundStyle(notice.unmatchedCount > 0 ? .orange : .secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Batch-fetch progress (shared by Transaction Mails and Statement Mails)

/// Count-based progress for a batch fetch, replacing what used to be a
/// single all-or-nothing spinner for the whole operation — "Processing 3
/// of 12…" plus a determinate ProgressView reassures that it's actually
/// moving, not stuck. The "~N remaining" estimate is a deliberately simple
/// average-time-per-item-so-far × remaining-count computation, recomputed
/// from `current`/`startedAt` on every view update (each increment to
/// `current` triggers one) rather than ticking on its own timer — good
/// enough for a rough estimate without adding a Timer/Combine subscription
/// to maintain. Hidden entirely (nil) until at least one item has finished,
/// since there's nothing to average yet before that.
private struct FetchProgressView: View {
    let current: Int
    let total: Int
    let startedAt: Date?

    private var estimatedSecondsRemaining: Int? {
        guard let startedAt, current > 0, current < total else { return nil }
        let elapsed = Date.now.timeIntervalSince(startedAt)
        let perItem = elapsed / Double(current)
        return Int((perItem * Double(total - current)).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Processing \(current) of \(total)…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(current), total: Double(max(total, 1)))
            if let estimatedSecondsRemaining, estimatedSecondsRemaining > 0 {
                Text("~\(formattedDuration(estimatedSecondsRemaining)) remaining")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) second\(seconds == 1 ? "" : "s")" }
        let minutes = max(seconds / 60, 1)
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
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
    @Query(sort: \Transaction.date) private var transactions: [Transaction]

    @AppStorage(AppSettings.gmailSenderTermsKey)
    private var senderTermsRaw = AppSettings.gmailSenderTermsDefault

    @State private var newSenderTerm = ""
    @State private var candidates: [EmailTransactionCandidate] = []
    @State private var isFetching = false
    @State private var fetchErrorMessage: String?
    @State private var editingCandidate: EmailTransactionCandidate?

    /// Batch-fetch progress — see FetchProgressView. totalToProcess is 0
    /// (and so the progress view stays hidden) until fetchCandidateMessages
    /// resolves and the actual count is known.
    @State private var processedCount = 0
    @State private var totalToProcess = 0
    @State private var fetchStartedAt: Date?

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

                    if isFetching && totalToProcess > 0 {
                        FetchProgressView(current: processedCount, total: totalToProcess, startedAt: fetchStartedAt)
                    }

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
                    .onDelete(perform: deleteCandidates)
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
                AddEditTransactionView(prefill: candidate.parsed, refundedTransaction: candidate.matchedRefundTransaction) {
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
        processedCount = 0
        totalToProcess = 0
        fetchStartedAt = nil
        Task {
            do {
                let messages = try await GmailFetcher.fetchCandidateMessages(senderTerms: senderTerms)
                totalToProcess = messages.count
                fetchStartedAt = .now
                var results: [EmailTransactionCandidate] = []
                for message in messages {
                    do {
                        let parsedRaw = try await EmailTransactionParser.parse(
                            emailBody: message.bodyText,
                            subject: message.subject,
                            categories: categories,
                            accounts: accounts
                        )
                        // Deterministic post-processing, not part of the
                        // model's own output — see matchRefund's doc comment.
                        let (parsed, matchedRefund) = EmailTransactionParser.matchRefund(
                            for: parsedRaw, against: transactions
                        )
                        results.append(EmailTransactionCandidate(
                            gmailMessageID: message.id,
                            rawSubject: message.subject,
                            rawSnippet: message.snippet,
                            parsed: parsed,
                            parseError: nil,
                            matchedRefundTransaction: matchedRefund
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
                    processedCount += 1
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

        let type = parsed.resolvedType
        let transaction = Transaction(
            amount: parsed.amount,
            date: parsed.resolvedDate,
            note: parsed.note ?? "",
            type: type,
            account: account,
            category: category
        )
        if type == .expense || type == .refund {
            let trimmedMerchant = parsed.merchantName?.trimmingCharacters(in: .whitespaces) ?? ""
            transaction.merchantName = trimmedMerchant.isEmpty ? nil : trimmedMerchant
        }
        if type == .refund {
            transaction.refundedTransaction = candidate.matchedRefundTransaction
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

    /// Dismisses candidates from this review session without importing
    /// them — nothing's been saved yet, so no confirmation and no
    /// GmailFetcher.markImported call either: unlike a real import, this
    /// doesn't need to survive a re-fetch, so the same email is free to
    /// come back as a candidate next time.
    private func deleteCandidates(at offsets: IndexSet) {
        candidates.remove(atOffsets: offsets)
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
                if let matched = candidate.matchedRefundTransaction {
                    Label("Matched refund for \(refundLabel(for: matched))", systemImage: "arrow.uturn.left")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                }
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

    /// Identifies the matched original expense for the "Matched refund
    /// for…" label — merchant name first, falling back to its note, so
    /// there's always something readable even when neither is set.
    private func refundLabel(for transaction: Transaction) -> String {
        if let merchant = transaction.merchantName, !merchant.isEmpty { return merchant }
        if !transaction.note.isEmpty { return transaction.note }
        return transaction.category?.name ?? "a purchase"
    }
}

// MARK: - Statement Mails (configure → fetch → review, one sheet)

/// Everything statement-related in one sheet, consolidated from what used
/// to be a separate Settings → Import Statement screen: a manual PDF picker
/// (with password-unlock support, including saving a password to Keychain
/// for silent auto-unlock next time — see KeychainStore.statementPassword)
/// alongside a Gmail search across configured statement senders. Both entry
/// points feed the same matched/possibly-missing results section below, so
/// there's one review list no matter which way a statement came in.
///
/// A Gmail fetch doesn't process anything blind: every matching email is
/// downloaded and shown as a selectable row (subject/sender/date) with its
/// lock status visible up front, silently trying a saved Keychain password
/// for locked ones first. Whatever's already unlocked processes on its own;
/// anything still locked waits for the user to tap that specific row, which
/// opens the very same PDFPasswordPromptSheet the manual pick uses — headed
/// with that email's subject/date, so it's never ambiguous which statement
/// a password is being entered for.

/// One row's state in Statement Mails' Fetched Emails list — locked/
/// unlocked is settled up front (see StatementMailsSheet.performFetch);
/// processing/done/failed track what happens after, whether that's
/// automatic (already unlocked) or triggered by tapping a locked row.
private enum FetchedEmailStatus: Equatable {
    case locked
    case unlocked
    case processing
    case done
    case failed(String)
}

/// One Gmail-fetched statement email paired with its downloaded PDF (nil
/// only when the attachment itself couldn't even be read as a PDF) and its
/// current FetchedEmailStatus.
private struct FetchedStatementEmail: Identifiable {
    var id: String { summary.id }
    let summary: GmailMessageSummary
    let document: PDFDocument?
    var status: FetchedEmailStatus
}

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

    /// Every email the last Gmail fetch found, each tracking its own lock/
    /// processing status — see FetchedStatementEmail below.
    @State private var fetchedEmails: [FetchedStatementEmail] = []

    /// Batch-fetch progress for the download/lock-check phase — see
    /// FetchProgressView. Once that phase finishes, fetchedEmails' own
    /// per-row status icons take over showing what's still happening
    /// (auto-processing already-unlocked rows), so this doesn't track the
    /// second phase too — that would just be a second, redundant progress
    /// indicator for the same work the list is already showing per-row.
    @State private var processedCount = 0
    @State private var totalToProcess = 0
    @State private var fetchStartedAt: Date?

    // Manual PDF pick (merged from the former StatementImportView)
    @State private var showingDocumentPicker = false

    // Password-protected PDFs — shared by both the manual pick and a
    // tapped locked row below. passwordContinuation is non-nil only while
    // a row tap's async wait is suspended on this same sheet — see
    // promptForPassword(document:emailContext:). pendingLockedEmailContext
    // is nil for the manual pick (no email to attribute the password to)
    // and set to that row's summary for a Gmail-fetched one, so the sheet
    // can show which statement the password is for.
    @State private var pendingLockedDocument: PDFDocument?
    @State private var pendingLockedEmailContext: GmailMessageSummary?
    @State private var showingPasswordPrompt = false
    @State private var passwordErrorMessage: String?
    @State private var passwordContinuation: CheckedContinuation<Bool, Never>?

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
                    // .listRowBackground/.listRowInsets strip the Section's
                    // default boxed-card row background — same fix as
                    // ProfileView's Logout button — so this reads as a
                    // plain full-width CTA rather than a colored pill sitting
                    // inside a white card. .listRowSeparator(.hidden) for
                    // the same reason: it's the only row in this Section, so
                    // there's no line to hide today, but nothing here
                    // guarantees that stays true if another row joins it later.
                    Button {
                        showingDocumentPicker = true
                    } label: {
                        if isFetching {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Choose Statement PDF")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
                    .disabled(isFetching)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                } footer: {
                    Text("Extracts every transaction line from a bank or card statement PDF and checks which ones are already logged in Panam. Works best with a text-based statement PDF — a scanned image can't be read. Password-protected statements are supported.")
                }

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

                    if isFetching && totalToProcess > 0 {
                        FetchProgressView(current: processedCount, total: totalToProcess, startedAt: fetchStartedAt)
                    }

                    if let fetchErrorMessage {
                        Text(fetchErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !fetchedEmails.isEmpty {
                    Section {
                        ForEach(fetchedEmails) { email in
                            Button {
                                rowTapped(email.id)
                            } label: {
                                FetchedEmailRow(summary: email.summary, status: email.status)
                            }
                            .buttonStyle(.plain)
                            .disabled(email.status != .locked)
                        }
                    } header: {
                        Text("Fetched Emails")
                    } footer: {
                        Text("Locked statements wait here until you tap them to enter a password — everything else processes on its own.")
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
                            .onDelete(perform: deleteUnmatched)
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
            .sheet(isPresented: $showingDocumentPicker) {
                PDFDocumentPicker { url in
                    handlePicked(url: url)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingPasswordPrompt, onDismiss: {
                pendingLockedDocument = nil
                pendingLockedEmailContext = nil
                // Dismissed without a successful unlock (Cancel, swipe-down)
                // — if a tapped row's async wait is suspended on this
                // prompt, let it resume and move on rather than hang forever.
                if let passwordContinuation {
                    self.passwordContinuation = nil
                    passwordContinuation.resume(returning: false)
                }
            }) {
                PDFPasswordPromptSheet(
                    accounts: accounts,
                    emailContext: pendingLockedEmailContext,
                    errorMessage: passwordErrorMessage
                ) { password, savePassword, manualAccount in
                    attemptUnlock(password: password, savePassword: savePassword, manualAccount: manualAccount)
                }
            }
        }
    }

    // MARK: - Manual file pick (merged from the former StatementImportView)

    private func handlePicked(url: URL) {
        fetchErrorMessage = nil
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            fetchErrorMessage = "Couldn't read that file."
            return
        }
        guard let document = PDFDocument(data: data) else {
            fetchErrorMessage = StatementReconcilerError.pdfUnreadable.errorDescription
            return
        }
        handle(document)
    }

    /// PDFDocument.isLocked is true for a password-protected PDF — checked
    /// here, once, before extraction. If any account has a Keychain-saved
    /// statement password, try all of them silently first — PDF decryption
    /// is a local, unlimited-attempt operation, so there's no cost to
    /// trying every saved password before ever bothering the user with a
    /// prompt.
    private func handle(_ document: PDFDocument) {
        guard document.isLocked else {
            processSingleDocument(document)
            return
        }
        if StatementReconciler.unlockWithSavedPassword(document, accounts: accounts) != nil {
            processSingleDocument(document)
            return
        }
        pendingLockedDocument = document
        pendingLockedEmailContext = nil
        passwordErrorMessage = nil
        showingPasswordPrompt = true
    }

    /// Shared by both entry points: pendingLockedDocument/passwordErrorMessage
    /// are the same state either way, and which document this actually is —
    /// the manual pick, or whichever Gmail attachment promptForPassword is
    /// currently suspended on — is transparent here. Only how success is
    /// reported differs: a batch-fetch prompt resumes its continuation so
    /// the awaiting loop in performFetch can continue; a manual pick has no
    /// continuation, so it drives extraction itself.
    private func attemptUnlock(password: String, savePassword: Bool, manualAccount: Account?) {
        guard let document = pendingLockedDocument else { return }
        guard document.unlock(withPassword: password) else {
            passwordErrorMessage = "That password didn't work. Try your date of birth as DDMMYYYY, your PAN, or whatever your bank's own convention is."
            return
        }
        showingPasswordPrompt = false
        pendingLockedDocument = nil

        if savePassword {
            let matchedAccount = manualAccount ?? (try? StatementReconciler.extractText(from: document))
                .flatMap { StatementReconciler.detectAccount(in: $0, accounts: accounts) }
            if let lastFour = matchedAccount?.lastFourDigits, !lastFour.isEmpty {
                KeychainStore.setStatementPassword(password, forLastFour: lastFour)
            }
        }

        if let passwordContinuation {
            self.passwordContinuation = nil
            passwordContinuation.resume(returning: true)
        } else {
            processSingleDocument(document)
        }
    }

    /// Suspends the caller (a tapped row's Task, see rowTapped(_:)) and
    /// presents the password prompt for `document`, headed with
    /// `emailContext`'s subject/date when this came from a Gmail row so
    /// it's clear which statement the password is for. Resumes once the
    /// user either unlocks it (true — document is mutated in place by
    /// PDFDocument.unlock, same as the manual pick path) or dismisses
    /// without success (false).
    private func promptForPassword(document: PDFDocument, emailContext: GmailMessageSummary?) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingLockedDocument = document
            pendingLockedEmailContext = emailContext
            passwordErrorMessage = nil
            passwordContinuation = continuation
            showingPasswordPrompt = true
        }
    }

    /// Runs one manually-picked PDF through the same extract → reconcile
    /// pipeline as the Gmail batch fetch below, writing into the very same
    /// matched/total/unmatched state — one shared results section serves
    /// both entry points, each overwriting whatever the other last found.
    private func processSingleDocument(_ document: PDFDocument) {
        isFetching = true
        fetchErrorMessage = nil
        Task {
            do {
                let text = try StatementReconciler.extractText(from: document)
                let entries = try await StatementReconciler.extractLineItems(from: text)
                let result = StatementReconciler.reconcile(
                    entries: entries, against: transactions, accounts: accounts
                )
                matchedCount = result.matchedCount
                totalCount = entries.count
                unmatched = result.unmatched
                isFetching = false
            } catch {
                isFetching = false
                fetchErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Sender configuration

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

    /// Searches Gmail for every matching statement email, then — instead of
    /// looping straight into extraction and interrupting sequentially for
    /// each locked one with no context — first downloads every attachment
    /// and settles each one's lock status (trying a saved Keychain
    /// password silently) into fetchedEmails, so the whole batch shows up
    /// as a selectable list with visible status before anything auto-
    /// processes or prompts. Once that's populated, whatever's already
    /// unlocked processes on its own; anything still locked just sits
    /// there until the user taps it — see rowTapped(_:).
    private func performFetch() {
        isFetching = true
        fetchErrorMessage = nil
        matchedCount = 0
        totalCount = 0
        unmatched = []
        fetchedEmails = []
        processedCount = 0
        totalToProcess = 0
        fetchStartedAt = nil

        Task {
            do {
                let summaries = try await GmailFetcher.searchStatementEmails(senderTerms: statementSenderTerms)
                guard !summaries.isEmpty else {
                    isFetching = false
                    fetchErrorMessage = "No statement emails found for these senders in the last 6 months."
                    return
                }
                totalToProcess = summaries.count
                fetchStartedAt = .now

                for summary in summaries {
                    guard let data = try? await GmailFetcher.downloadAttachment(
                        messageID: summary.id, attachmentID: summary.attachmentID
                    ), let document = PDFDocument(data: data) else {
                        fetchedEmails.append(FetchedStatementEmail(
                            summary: summary, document: nil,
                            status: .failed("Couldn't read this attachment as a PDF.")
                        ))
                        processedCount += 1
                        continue
                    }
                    if document.isLocked {
                        _ = StatementReconciler.unlockWithSavedPassword(document, accounts: accounts)
                    }
                    fetchedEmails.append(FetchedStatementEmail(
                        summary: summary, document: document,
                        status: document.isLocked ? .locked : .unlocked
                    ))
                    processedCount += 1
                }
                isFetching = false

                for index in fetchedEmails.indices where fetchedEmails[index].status == .unlocked {
                    await processRow(at: index)
                }
            } catch {
                isFetching = false
                fetchErrorMessage = error.localizedDescription
            }
        }
    }

    /// Runs one fetched email's already-unlocked PDF through the same
    /// extract → reconcile pipeline as the manual pick, adding its results
    /// into the shared matched/total/unmatched state rather than
    /// overwriting it — every row's contribution accumulates.
    private func processRow(at index: Int) async {
        guard let document = fetchedEmails[index].document else { return }
        fetchedEmails[index].status = .processing
        do {
            let text = try StatementReconciler.extractText(from: document)
            let entries = try await StatementReconciler.extractLineItems(from: text)
            let result = StatementReconciler.reconcile(
                entries: entries, against: transactions, accounts: accounts
            )
            matchedCount += result.matchedCount
            totalCount += entries.count
            unmatched.append(contentsOf: result.unmatched)
            fetchedEmails[index].status = .done
        } catch {
            fetchedEmails[index].status = .failed(error.localizedDescription)
        }
    }

    /// A locked row's tap target: prompts for that specific email's
    /// password (headed with its subject/date), and on success unlocks and
    /// processes it. Anything but a still-locked row is a no-op — the
    /// button is disabled for every other status anyway.
    private func rowTapped(_ id: String) {
        guard let index = fetchedEmails.firstIndex(where: { $0.id == id }),
              fetchedEmails[index].status == .locked,
              let document = fetchedEmails[index].document
        else { return }

        Task {
            let unlocked = await promptForPassword(document: document, emailContext: fetchedEmails[index].summary)
            guard unlocked else { return }
            fetchedEmails[index].status = .unlocked
            await processRow(at: index)
        }
    }

    /// Unlike Transaction Mails' quick-import (which requires both an
    /// account AND a category to resolve), a statement line never carries
    /// a category — StatementReconciler doesn't ask the model to guess one
    /// (see StatementLineItem). Requiring one here would make quick-import
    /// permanently unusable, so this only requires the account to resolve;
    /// the transaction is created uncategorized, same as any manually
    /// entered one left that way.
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

    /// Dismisses candidates from this review list without importing them —
    /// nothing's been saved yet, so no confirmation needed. Purely a "stop
    /// showing me this line" action: it doesn't touch matchedCount/
    /// totalCount, so the "Matched X of Y" summary above still reflects
    /// what the statement actually contained.
    private func deleteUnmatched(at offsets: IndexSet) {
        unmatched.remove(atOffsets: offsets)
    }
}

/// One row in Statement Mails' Fetched Emails list: subject/sender/date
/// plus a trailing status icon — a lock for one still waiting on a
/// password, a spinner while it's being extracted/reconciled, a checkmark
/// once done, or a warning if it couldn't be processed. Only a .locked row
/// is an actual tap target (see StatementMailsSheet.rowTapped(_:)); every
/// other status is just a status display.
private struct FetchedEmailRow: View {
    let summary: GmailMessageSummary
    let status: FetchedEmailStatus

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.subject)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack {
                    Text(summary.from)
                        .lineLimit(1)
                    Spacer()
                    Text(summary.dateString)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if case .failed(let message) = status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            statusIcon
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .locked:
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
        case .unlocked:
            Image(systemName: "lock.open.fill")
                .foregroundStyle(.secondary)
        case .processing:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
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

// MARK: - Manual file picker (UIDocumentPickerViewController)

/// Wraps UIDocumentPickerViewController restricted to PDFs — SwiftUI has no
/// native file-picker view (unlike PhotosPicker for images). Moved here
/// from the former StatementImportView along with the rest of the manual
/// pick flow.
private struct PDFDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - Password prompt

private struct PDFPasswordPromptSheet: View {
    let accounts: [Account]
    /// The Gmail-fetched email this password is for — shown up top (subject
    /// + date) so it's never ambiguous which statement is being unlocked.
    /// nil for the manual-pick path, where there's no email to attribute it to.
    let emailContext: GmailMessageSummary?
    let errorMessage: String?
    /// (password, save to Keychain?, manually-picked account — nil means
    /// "auto-detect from the statement" when saving is on).
    let onUnlock: (String, Bool, Account?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var savePassword = false
    @State private var manualAccountID: PersistentIdentifier?

    /// Only accounts with a last-4 on file can be keyed into Keychain or
    /// auto-detected, so that's all the picker offers.
    private var eligibleAccounts: [Account] {
        accounts.filter { !($0.lastFourDigits ?? "").isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let emailContext {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(emailContext.subject)
                                .font(.subheadline)
                            HStack {
                                Text(emailContext.from)
                                    .lineLimit(1)
                                Spacer()
                                Text(emailContext.dateString)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Statement Email")
                    }
                }

                Section {
                    SecureField("Password", text: $password)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("This statement PDF is password-protected. Common conventions: date of birth as DDMMYYYY, your PAN, or your bank's own format.")
                }

                Section {
                    Toggle("Save password for this card", isOn: $savePassword)

                    if savePassword && !eligibleAccounts.isEmpty {
                        Picker("Card", selection: $manualAccountID) {
                            Text("Auto-detect").tag(PersistentIdentifier?.none)
                            ForEach(eligibleAccounts) { account in
                                Text("\(account.name) •••• \(account.lastFourDigits ?? "")")
                                    .tag(Optional(account.persistentModelID))
                            }
                        }
                    }
                } footer: {
                    if savePassword {
                        Text("Panam will try this password automatically the next time it needs to unlock a statement for this card.")
                    }
                }
            }
            .navigationTitle("Enter Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock") {
                        let manualAccount = eligibleAccounts.first { $0.persistentModelID == manualAccountID }
                        onUnlock(password, savePassword, manualAccount)
                    }
                    .disabled(password.isEmpty)
                }
            }
        }
    }
}

#Preview {
    EmailManagementView()
        .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
