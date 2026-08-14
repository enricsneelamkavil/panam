//
//  StatementImportView.swift
//  Panam
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit

/// Entry point for bank-statement reconciliation: pick a PDF (manually, or
/// found via Gmail search), unlock it if it's password-protected, extract
/// its text, ask the on-device model for every line item, then compare
/// against existing transactions. Most of the actual work lives in
/// StatementReconciler / GmailFetcher — this view is the picker plumbing,
/// the password prompt, and progress/error UI around them.
struct StatementImportView: View {
    @Query(sort: \Transaction.date) private var transactions: [Transaction]
    @Query(sort: \Account.name) private var accounts: [Account]

    @AppStorage(AppSettings.statementSenderTermsKey)
    private var statementSenderTermsRaw = AppSettings.statementSenderTermsDefault

    private var statementSenderTerms: [String] {
        statementSenderTermsRaw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @State private var showingDocumentPicker = false
    @State private var isProcessing = false
    @State private var errorMessage: String?

    // Fetch from Email
    @State private var showingEmailSearch = false
    @State private var isSearchingEmail = false
    @State private var emailSummaries: [GmailMessageSummary] = []
    @State private var emailSearchErrorMessage: String?

    // Password-protected PDFs
    @State private var pendingLockedDocument: PDFDocument?
    @State private var showingPasswordPrompt = false
    @State private var passwordErrorMessage: String?

    // Result
    @State private var matchedCount = 0
    @State private var totalCount = 0
    @State private var unmatched: [StatementReconciliationCandidate] = []
    @State private var showingResult = false

    var body: some View {
        Form {
            Section {
                Button {
                    showingDocumentPicker = true
                } label: {
                    Text("Choose Statement PDF")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
                .disabled(isProcessing)

                Button {
                    startEmailSearch()
                } label: {
                    Text("Fetch from Email")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
                .disabled(isProcessing)

                if isProcessing {
                    ProgressView("Reading statement…")
                        .frame(maxWidth: .infinity)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Extracts every transaction line from a bank or card statement PDF and checks which ones are already logged in Panam. Works best with a text-based statement PDF — a scanned image can't be read. Password-protected statements are supported.")
            }
        }
        .navigationTitle("Import Statement")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingDocumentPicker) {
            PDFDocumentPicker { url in
                handlePicked(url: url)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingEmailSearch) {
            StatementEmailSearchSheet(
                summaries: emailSummaries,
                isSearching: isSearchingEmail,
                errorMessage: emailSearchErrorMessage
            ) { summary in
                showingEmailSearch = false
                downloadAndHandle(summary)
            }
        }
        .sheet(isPresented: $showingPasswordPrompt, onDismiss: { pendingLockedDocument = nil }) {
            PDFPasswordPromptSheet(errorMessage: passwordErrorMessage) { password in
                attemptUnlock(password: password)
            }
        }
        .navigationDestination(isPresented: $showingResult) {
            StatementReconciliationView(matchedCount: matchedCount, totalCount: totalCount, unmatched: unmatched)
        }
    }

    // MARK: - Manual file pick

    private func handlePicked(url: URL) {
        errorMessage = nil
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn't read that file."
            return
        }
        guard let document = PDFDocument(data: data) else {
            errorMessage = StatementReconcilerError.pdfUnreadable.errorDescription
            return
        }
        handle(document)
    }

    // MARK: - Fetch from Email

    private func startEmailSearch() {
        showingEmailSearch = true
        emailSummaries = []
        emailSearchErrorMessage = nil

        guard !statementSenderTerms.isEmpty else {
            emailSearchErrorMessage = "Add at least one statement sender in Profile → Statement Search first."
            return
        }

        isSearchingEmail = true
        Task {
            do {
                emailSummaries = try await GmailFetcher.searchStatementEmails(senderTerms: statementSenderTerms)
                isSearchingEmail = false
            } catch {
                emailSearchErrorMessage = error.localizedDescription
                isSearchingEmail = false
            }
        }
    }

    private func downloadAndHandle(_ summary: GmailMessageSummary) {
        isProcessing = true
        errorMessage = nil
        Task {
            do {
                let data = try await GmailFetcher.downloadAttachment(
                    messageID: summary.id, attachmentID: summary.attachmentID
                )
                guard let document = PDFDocument(data: data) else {
                    throw StatementReconcilerError.pdfUnreadable
                }
                isProcessing = false
                handle(document)
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Password + shared pipeline

    /// PDFDocument.isLocked is true for a password-protected PDF regardless
    /// of how it was obtained — check it here, once, before either
    /// pipeline (manual pick or email download) proceeds to extraction.
    private func handle(_ document: PDFDocument) {
        if document.isLocked {
            pendingLockedDocument = document
            passwordErrorMessage = nil
            showingPasswordPrompt = true
        } else {
            continueProcessing(document)
        }
    }

    private func attemptUnlock(password: String) {
        guard let document = pendingLockedDocument else { return }
        guard document.unlock(withPassword: password) else {
            passwordErrorMessage = "That password didn't work. Try your date of birth as DDMMYYYY, your PAN, or whatever your bank's own convention is."
            return
        }
        showingPasswordPrompt = false
        pendingLockedDocument = nil
        continueProcessing(document)
    }

    private func continueProcessing(_ document: PDFDocument) {
        isProcessing = true
        errorMessage = nil
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
                isProcessing = false
                showingResult = true
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Manual file picker (UIDocumentPickerViewController)

/// Wraps UIDocumentPickerViewController restricted to PDFs — SwiftUI has no
/// native file-picker view (unlike PhotosPicker for images).
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

// MARK: - Fetch from Email: search results

private struct StatementEmailSearchSheet: View {
    let summaries: [GmailMessageSummary]
    let isSearching: Bool
    let errorMessage: String?
    let onSelect: (GmailMessageSummary) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView("Searching Gmail…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if summaries.isEmpty {
                    Text("No statement emails found for the configured senders in the last 6 months.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(summaries) { summary in
                        Button {
                            onSelect(summary)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.subject)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                HStack {
                                    Text(summary.from)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(summary.dateString)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Statement Emails")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Password prompt

private struct PDFPasswordPromptSheet: View {
    let errorMessage: String?
    let onUnlock: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
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
            }
            .navigationTitle("Enter Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock") {
                        onUnlock(password)
                    }
                    .disabled(password.isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        StatementImportView()
    }
    .modelContainer(for: [Account.self, Category.self, Transaction.self], inMemory: true)
}
