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

    /// Same date + amount + description (trimmed, case-insensitive) — used
    /// only to collapse the near-boundary repeats two overlapping chunks
    /// can produce for the same physical row, never as a general-purpose
    /// equality check.
    func isLikelyDuplicate(of other: StatementLineItem) -> Bool {
        dateString == other.dateString
            && abs(amount - other.amount) < 0.01
            && description.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
                other.description.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
    }
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
    /// directly, so the caller (EmailManagementView's StatementMailsSheet)
    /// can check `document.isLocked` and run its own password-unlock flow
    /// first — whether the PDF came from the file picker or a downloaded
    /// Gmail attachment, both converge on a PDFDocument before reaching here.
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

    /// Cheap, synchronous account guess for a just-unlocked statement — used
    /// only to offer a sensible default when the user opts to save its
    /// password (see EmailManagementView's StatementMailsSheet), not for
    /// reconciliation itself.
    /// Just checks whether any account's last-4 appears verbatim in the
    /// statement text (a header like "Card ending 1234" almost always
    /// contains it); if several accounts' last-4 happen to match, this
    /// picks the first and the caller lets the user override it.
    static func detectAccount(in text: String, accounts: [Account]) -> Account? {
        accounts.first {
            guard let lastFour = $0.lastFourDigits, !lastFour.isEmpty else { return false }
            return text.contains(lastFour)
        }
    }

    /// Tries every candidate account's Keychain-saved statement password
    /// (see KeychainStore.statementPassword) against a locked document,
    /// mutating it in place via PDFDocument.unlock the moment one works.
    /// PDF decryption is local and unlimited-attempt, so trying every saved
    /// password is cheap and safe. Returns the account whose password
    /// worked — both a Bool ("did it unlock") and an identity (StatementAutoFetchProcessor
    /// needs to know *which* due card a locked statement belongs to, not
    /// just that it opened).
    static func unlockWithSavedPassword(_ document: PDFDocument, accounts: [Account]) -> Account? {
        accounts.first { account in
            guard let lastFour = account.lastFourDigits, !lastFour.isEmpty,
                  let password = KeychainStore.statementPassword(forLastFour: lastFour) else { return false }
            return document.unlock(withPassword: password)
        }
    }

    // MARK: Line-item extraction

    /// The on-device model's context window is a fixed 4,096 tokens shared
    /// across instructions + prompt + output (Apple TN3193 "Managing the
    /// on-device foundation model's context window") — far smaller than a
    /// cloud model's, and easily blown past by a multi-page statement's
    /// full extracted text in one call. There's no public tokenizer to
    /// measure exactly, so this budgets characters using the commonly-cited
    /// ~4-characters-per-token rule of thumb, conservatively, leaving
    /// headroom for the instructions text, the injected @Generable schema,
    /// and a chunk with many transaction lines producing a correspondingly
    /// large generated response.
    private static let maxChunkCharacters = 2500
    /// Repeated at the head of the next chunk so a transaction row that
    /// falls right at a boundary reads complete (not truncated) in at
    /// least one chunk — extractLineItems then drops the resulting
    /// near-boundary repeats, see appendDeduping(_:to:).
    private static let chunkOverlapCharacters = 250
    /// Below this, a chunk that still overflows the context window is
    /// dropped rather than halved and retried again — something that small
    /// overflowing means a pathologically dense/unbroken section, not
    /// something another split would fix.
    private static let minSplittableCharacters = 300
    /// How far back to look for an overlap-caused repeat when merging a
    /// chunk's entries into the running list — generous relative to how
    /// many rows chunkOverlapCharacters actually spans, and deliberately
    /// local: two genuinely identical purchases elsewhere on the statement
    /// (same date/amount/merchant) are real, distinct transactions, not
    /// duplicates, so this never compares against anything but the
    /// most-recently-added entries.
    private static let dedupLookback = 8

    /// Feeds the statement's raw text to the on-device model, asking for
    /// every transaction line rather than a summary — see
    /// StatementExtraction.entries' @Guide. Statement formats vary wildly
    /// bank to bank, so treat the first real run against your own
    /// statements as a calibration pass: the instructions below will
    /// likely need tuning once you see actual output, the same as email
    /// parsing did.
    ///
    /// Splits the text into chunks well under the context window before
    /// calling the model at all (see maxChunkCharacters) — one page of a
    /// statement can already run to several thousand characters, and a
    /// full multi-page statement in one call is exactly what triggers
    /// GenerationError.exceededContextWindowSize. Each chunk runs in its
    /// own fresh session and its entries are merged into one combined list.
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
            You will be given a section of the raw text extracted from a \
            bank or credit card statement PDF — possibly the whole \
            statement, possibly just one part of a longer one. Amounts are \
            in Indian rupees.

            Find every individual transaction line in this section — this \
            is usually a table with a date, a description/narration, and an \
            amount (sometimes split into separate debit/credit columns, or \
            marked with "Dr"/"Cr"). Extract EVERY line in THIS section as \
            its own entry. Do not summarize, do not report only a few \
            examples, and do not merge multiple lines into one — if this \
            section contains 20 transaction lines, produce 20 entries.

            Ignore lines that aren't individual transactions: statement \
            headers, running/opening/closing balance lines, page \
            footers, and marketing text.

            The text may contain OCR/extraction noise — misaligned columns, \
            odd line breaks, stray whitespace — use your best judgment to \
            recover each line's real date, amount, and description.
            """

        var allEntries: [StatementLineItem] = []
        for chunk in chunkedByLines(statementText, maxCharacters: maxChunkCharacters, overlapCharacters: chunkOverlapCharacters) {
            let chunkEntries = await extractLineItemsWithRetry(chunk: chunk, instructions: instructions)
            appendDeduping(chunkEntries, to: &allEntries)
        }
        return allEntries
    }

    /// Splits `text` into whole-line chunks of at most `maxCharacters`,
    /// each (after the first) opening with the previous chunk's trailing
    /// `overlapCharacters` worth of lines repeated verbatim — chosen over a
    /// raw character split so a chunk boundary never lands mid-row.
    private static func chunkedByLines(_ text: String, maxCharacters: Int, overlapCharacters: Int) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }

        var chunks: [String] = []
        var currentLines: [String] = []
        var currentLength = 0

        for line in lines {
            let lineLength = line.count + 1 // +1 for the joining newline
            if currentLength + lineLength > maxCharacters && !currentLines.isEmpty {
                chunks.append(currentLines.joined(separator: "\n"))
                currentLines = trailingLines(currentLines, maxCharacters: overlapCharacters)
                currentLength = currentLines.reduce(0) { $0 + $1.count + 1 }
            }
            currentLines.append(line)
            currentLength += lineLength
        }
        if !currentLines.isEmpty {
            chunks.append(currentLines.joined(separator: "\n"))
        }
        return chunks
    }

    private static func trailingLines(_ lines: [String], maxCharacters: Int) -> [String] {
        var result: [String] = []
        var length = 0
        for line in lines.reversed() {
            let lineLength = line.count + 1
            if length + lineLength > maxCharacters && !result.isEmpty { break }
            result.insert(line, at: 0)
            length += lineLength
        }
        return result
    }

    /// Runs one chunk through the model. If the chunk alone still overflows
    /// the context window — the character-per-token estimate is a rule of
    /// thumb, not exact, so a dense chunk right at the budget can still do
    /// this — halves it and retries each half instead of failing the whole
    /// import over one oversized section. Any other error (model
    /// momentarily unavailable, a decoding failure, etc.) is likewise
    /// swallowed here for the same reason: one bad chunk shouldn't sink a
    /// multi-page statement's worth of otherwise-good chunks.
    private static func extractLineItemsWithRetry(chunk: String, instructions: String) async -> [StatementLineItem] {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: chunk, generating: StatementExtraction.self)
            return response.content.entries
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize(_) {
            guard chunk.count > minSplittableCharacters else { return [] }
            var entries: [StatementLineItem] = []
            for half in splitInHalf(chunk) {
                entries.append(contentsOf: await extractLineItemsWithRetry(chunk: half, instructions: instructions))
            }
            return entries
        } catch {
            return []
        }
    }

    /// Splits on the middle line where possible (keeps rows intact); falls
    /// back to a raw character midpoint only for a chunk with no newline to
    /// split on at all.
    private static func splitInHalf(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else {
            let midIndex = text.index(text.startIndex, offsetBy: text.count / 2)
            return [String(text[..<midIndex]), String(text[midIndex...])]
        }
        let mid = lines.count / 2
        return [lines[..<mid].joined(separator: "\n"), lines[mid...].joined(separator: "\n")]
    }

    /// Appends one chunk's entries to the running aggregate, skipping any
    /// that exactly repeat one of the last dedupLookback entries already
    /// there — the overlap between consecutive chunks can hand back the
    /// same row twice, and because chunks are processed in order, a repeat
    /// like that always lands immediately adjacent in the merged list.
    private static func appendDeduping(_ newEntries: [StatementLineItem], to aggregate: inout [StatementLineItem]) {
        for entry in newEntries {
            let recentTail = aggregate.suffix(dedupLookback)
            if recentTail.contains(where: { $0.isLikelyDuplicate(of: entry) }) { continue }
            aggregate.append(entry)
        }
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
