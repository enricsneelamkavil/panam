import Foundation
import PDFKit
import FoundationModels

// MARK: - Extraction schema

/// One line item as printed on a bank/card statement — deliberately just
/// the raw facts the model can actually read off the page (no category or
/// account-name guessing, unlike ParsedTransaction) since a statement line
/// rarely states either.
@Generable
struct StatementLineItem {
    @Guide(description: "The transaction date as printed, resolved to yyyy-MM-dd (ISO 8601)")
    var dateString: String

    @Guide(description: "The transaction amount as a positive number, regardless of how debit/credit is denoted on the statement")
    var amount: Double

    @Guide(description: "The line's description/narration/merchant text exactly as printed")
    var description: String

    @Guide(description: "Last 4 digits of the card/account number this line is associated with, if visible anywhere on the statement (e.g. a header like \"Card ending 1234\"), or nil if none is shown")
    var lastFourDigits: String?
}

/// The model's full response for one statement — a flat list, not a
/// summary. Wrapping the array in its own @Generable type (rather than
/// generating `[StatementLineItem]` directly) is what lets
/// LanguageModelSession target a list-of-many-items response at all.
@Generable
struct StatementExtraction {
    @Guide(description: "Every transaction line item found in the statement text, in the order they appear on the statement. Include every line — do not summarize, merge, deduplicate, or skip any of them, even if there are many.")
    var entries: [StatementLineItem]
}

// MARK: - Errors

enum StatementReconcilerError: LocalizedError {
    case modelUnavailable(String)
    case noExtractableText
    case pdfUnreadable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return reason
        case .noExtractableText:
            return "No text could be extracted from this PDF. It may be password-protected, or a scanned image rather than real text — try exporting a text-based statement instead."
        case .pdfUnreadable:
            return "Couldn't open that file as a PDF."
        }
    }
}

// MARK: - A reconciliation candidate: an unmatched statement line

/// A statement line item that didn't match any existing Transaction —
/// "you may have forgotten to log this." Carries a ParsedTransaction so it
/// can flow through the exact same Edit sheet (AddEditTransactionView) as
/// voice/email/receipt entries.
struct StatementReconciliationCandidate: Identifiable {
    let id = UUID()
    let rawDescription: String
    let parsed: ParsedTransaction
}

enum StatementReconciler {
    // MARK: PDF text extraction

    /// PDFKit's PDFPage.string only recovers text for text-based PDFs — a
    /// scanned/photographed statement (image-only pages) or a
    /// password-protected one both come back empty here, which is exactly
    /// when callers should show StatementReconcilerError.noExtractableText
    /// instead of silently treating "no matches" as the outcome.
    ///
    /// Takes an already-constructed PDFDocument rather than a URL/Data
    /// directly, so the caller (StatementImportView) can check
    /// `document.isLocked` and run its own password-unlock flow first —
    /// whether the PDF came from the file picker or a downloaded Gmail
    /// attachment, both converge on a PDFDocument before reaching here.
    static func extractText(from document: PDFDocument) throws -> String {
        var text = ""
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if let pageText = page.string {
                text += pageText + "\n"
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StatementReconcilerError.noExtractableText
        }
        return text
    }

    // MARK: Line-item extraction

    /// Feeds the statement's raw text to the on-device model, asking for
    /// every transaction line rather than a summary — see
    /// StatementExtraction.entries' @Guide. Statement formats vary wildly
    /// bank to bank, so treat the first real run against your own
    /// statements as a calibration pass: the instructions below will
    /// likely need tuning once you see actual output, the same as email
    /// parsing did.
    static func extractLineItems(from statementText: String) async throws -> [StatementLineItem] {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw StatementReconcilerError.modelUnavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw StatementReconcilerError.modelUnavailable("Turn on Apple Intelligence in Settings to reconcile statements.")
        case .unavailable(.modelNotReady):
            throw StatementReconcilerError.modelUnavailable("The on-device model isn't ready yet. Try again in a bit.")
        case .unavailable:
            throw StatementReconcilerError.modelUnavailable("The on-device model is unavailable.")
        }

        let instructions = """
            You will be given the raw text extracted from a bank or credit \
            card statement PDF. Amounts are in Indian rupees.

            Find every individual transaction line in the statement — this \
            is usually a table with a date, a description/narration, and an \
            amount (sometimes split into separate debit/credit columns, or \
            marked with "Dr"/"Cr"). Extract EVERY line as its own entry. Do \
            not summarize the statement, do not report only a few examples, \
            and do not merge multiple lines into one — a 3-page statement \
            with 60 transactions should produce 60 entries.

            Ignore lines that aren't individual transactions: statement \
            headers, running/opening/closing balance lines, page \
            footers, and marketing text.

            The text may contain OCR/extraction noise — misaligned columns, \
            odd line breaks, stray whitespace — use your best judgment to \
            recover each line's real date, amount, and description.
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: statementText, generating: StatementExtraction.self)
        return response.content.entries
    }

    // MARK: Reconciliation

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// ±1 day — a statement's printed date and the actual transaction date
    /// Panam recorded commonly drift by a day (posting date vs. the date
    /// you logged it, timezone rounding, etc.).
    private static let dateToleranceDays = 1

    /// Compares each extracted line against `transactions`: same date
    /// (±1 day), same amount, and — only when the line names a card/account
    /// via last-4 — the same resolved account. A line with no last-4 is
    /// matched on date+amount alone, same as the other two conditions
    /// being sufficient when there's nothing more specific to check.
    static func reconcile(
        entries: [StatementLineItem],
        against transactions: [Transaction],
        accounts: [Account]
    ) -> (matchedCount: Int, unmatched: [StatementReconciliationCandidate]) {
        var matchedCount = 0
        var unmatched: [StatementReconciliationCandidate] = []

        for entry in entries {
            if isMatched(entry, in: transactions, accounts: accounts) {
                matchedCount += 1
            } else {
                unmatched.append(candidate(for: entry, accounts: accounts))
            }
        }
        return (matchedCount, unmatched)
    }

    private static func isMatched(_ entry: StatementLineItem, in transactions: [Transaction], accounts: [Account]) -> Bool {
        guard let entryDate = dateFormat.date(from: entry.dateString) else { return false }
        let resolvedAccount = resolveAccount(entry.lastFourDigits, accounts: accounts)

        return transactions.contains { transaction in
            guard withinTolerance(transaction.date, entryDate) else { return false }
            guard amountsMatch(transaction.amount, entry.amount) else { return false }
            if let resolvedAccount {
                return transaction.account == resolvedAccount
            }
            return true
        }
    }

    private static func withinTolerance(_ a: Date, _ b: Date) -> Bool {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? Int.max
        return abs(days) <= dateToleranceDays
    }

    private static func amountsMatch(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.01
    }

    private static func resolveAccount(_ lastFourDigits: String?, accounts: [Account]) -> Account? {
        let trimmed = lastFourDigits?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return accounts.first { $0.lastFourDigits == trimmed }
    }

    /// Builds the review candidate — a ParsedTransaction with no
    /// categoryName/accountName guess (the statement schema never asked
    /// the model for either), just the date/amount/description/last-4 the
    /// line actually carries. Feeds straight into the same
    /// AddEditTransactionView(prefill:) sheet every other entry point uses.
    private static func candidate(for entry: StatementLineItem, accounts: [Account]) -> StatementReconciliationCandidate {
        let parsed = ParsedTransaction(
            amount: entry.amount,
            type: "expense",
            categoryName: nil,
            accountName: nil,
            note: entry.description,
            merchantName: entry.description,
            lastFourDigits: entry.lastFourDigits,
            resolvedDateString: entry.dateString,
            paymentMethodName: nil
        )
        return StatementReconciliationCandidate(rawDescription: entry.description, parsed: parsed)
    }
}
