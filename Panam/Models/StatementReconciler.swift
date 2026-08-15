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
    @Guide(description: "The transaction date, converted to STRICT yyyy-MM-dd (ISO 8601) format only — 4-digit year, then 2-digit month, then 2-digit day, separated by hyphens. Do NOT copy the date the way it's printed on the statement: a date printed as \"14/07/2026\", \"14-07-2026\", or \"14 Jul 2026\" must all be converted and written as \"2026-07-14\". Never day-first, never slash-separated, never a month name in the output.")
    var dateString: String

    @Guide(description: "The transaction amount as a positive number, regardless of how debit/credit is denoted on the statement")
    var amount: Double

    @Guide(description: "True if this specific line is a credit — money added to the account, often marked \"Cr\", printed in a separate Credit column, or described as a refund/reversal/cashback. False if it's a debit — money spent, often marked \"Dr\" or printed in a separate Debit column. Most statement lines are debits; only set true when the statement clearly shows this particular line as a credit.")
    var isCredit: Bool

    @Guide(description: "The line's description/narration/merchant text exactly as printed")
    var description: String

    @Guide(description: "Last 4 digits of the card/account number this line is associated with, if visible anywhere on the statement (e.g. a header like \"Card ending 1234\"), or nil if none is shown")
    var lastFourDigits: String?

    @Guide(description: "Only true if this is a real row from the statement's actual transaction table — a specific date, a specific single amount, and a description for one transaction that happened on that date. False for a fee schedule row, an interest rate/calculation row, a reward points summary row, terms and conditions text, or a promotional insert, even if it mentions rupee amounts.")
    var isGenuineTransaction: Bool

    /// Same date + amount + direction + description (trimmed,
    /// case-insensitive) — used only to collapse the near-boundary repeats
    /// two overlapping chunks can produce for the same physical row, never
    /// as a general-purpose equality check. isCredit is part of the
    /// comparison so a same-day, same-amount debit and its own credit
    /// reversal are never mistaken for one duplicated row.
    func isLikelyDuplicate(of other: StatementLineItem) -> Bool {
        dateString == other.dateString
            && abs(amount - other.amount) < 0.01
            && isCredit == other.isCredit
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
    /// Set when EmailTransactionParser.matchRefund found an existing debit
    /// this credit line looks like a refund for — `parsed` has already been
    /// reclassified to .refund by that point (see
    /// StatementReconciler.candidate(for:accounts:transactions:)). Carried
    /// along purely for display (the "Matched refund for…" review label,
    /// same as EmailTransactionCandidate's identically-named field) and so
    /// the eventual Transaction can link back to it via `refundedTransaction`.
    var matchedRefundTransaction: Transaction? = nil
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
    /// Not private: DematHoldingExtractor reuses this same chunking budget
    /// (and chunkedByLines/minSplittableCharacters/splitInHalf below) for
    /// the identical reason — a holdings statement can run just as long as
    /// a transaction one before it ever reaches the model.
    static let maxChunkCharacters = 2500
    /// Repeated at the head of the next chunk so a transaction row that
    /// falls right at a boundary reads complete (not truncated) in at
    /// least one chunk — extractLineItems then drops the resulting
    /// near-boundary repeats, see appendDeduping(_:to:).
    static let chunkOverlapCharacters = 250
    /// Below this, a chunk that still overflows the context window is
    /// dropped rather than halved and retried again — something that small
    /// overflowing means a pathologically dense/unbroken section, not
    /// something another split would fix.
    static let minSplittableCharacters = 300
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
            marked with "Dr"/"Cr"). For each line, also decide whether it's \
            a debit or a credit — look for a "Dr"/"Cr" suffix, which of two \
            separate Debit/Credit columns the amount sits in, or wording \
            like "refund"/"reversal"/"cashback credited" — and set isCredit \
            accordingly; most lines on a card statement are debits. Extract \
            EVERY line in THIS section as its own entry. Do not summarize, \
            do not report only a few examples, and do not merge multiple \
            lines into one — if this section contains 20 transaction \
            lines, produce 20 entries.

            Ignore lines that aren't individual transactions: statement \
            headers, running/opening/closing balance lines, page footers, \
            and marketing text. This includes a statement's own closing/ \
            disclaimer block — "this is a computer generated statement," \
            "this statement does not require a signature," customer-care \
            contact details, a registered/corporate office address, a \
            grievance-redressal officer's name, or a generic sign-off like \
            "Regards" / "Thank you for banking with us." None of that is a \
            transaction, even when it sits right next to the transaction \
            table or repeats at the bottom of every page.

            Only extract rows from the actual transaction/statement table \
            — each with a specific date, a specific single amount, and a \
            transaction description naming a real merchant/payee. Do NOT \
            extract: fee schedule tables, interest rate tables, reward \
            points summaries, terms and conditions text, promotional \
            inserts, or the closing disclaimer/contact-info block described \
            above, even if they contain rupee amounts.

            Bank statements commonly include a worked EXAMPLE explaining \
            how Interest or the Minimum Amount Due is calculated — look \
            for section headers like "Illustration", "Scenario A" / \
            "Scenario B", "the following illustration will indicate...", \
            or a made-up walkthrough with generic line items ("EMI \
            Principal", "EMI Interest", "Processing Fee", "Late Payment \
            Fee", "Purchase on <date>" with no merchant named, "Total \
            Amount Due", "Minimum Amount Due"). This is instructional \
            boilerplate, not something that happened on this customer's \
            account, even though it's laid out with dates and amounts \
            exactly like a real transaction table and even though every \
            number in it is really printed on the page. Do not extract \
            any row from it, no matter how transaction-like it looks.

            A genuine transaction row almost always names a specific \
            merchant or payee (a store, an app, a person, a biller). A \
            row whose only description is a generic label like "Purchase" \
            or a fee/interest/EMI line item with no merchant name is a \
            strong signal it belongs to one of the excluded sections \
            above, not the customer's real transaction table.

            Set isGenuineTransaction to false for any row drawn from one \
            of the excluded sections above instead of the real transaction \
            table — false entries are discarded, so when in doubt about \
            whether a row is a genuine transaction, still include it but \
            mark it accordingly rather than omitting it outright.

            If this section contains no real transaction rows at all — for \
            example it's entirely a fee schedule, an interest-calculation \
            breakdown, a Minimum-Amount-Due illustration, or T&Cs/legal \
            text — return an empty list. Never invent a transaction, and \
            never repurpose an illustration's example figures as if they \
            were this customer's real transactions, to fill the response.

            The text may contain OCR/extraction noise — misaligned columns, \
            odd line breaks, stray whitespace — use your best judgment to \
            recover each line's real date, amount, and description.
            """

        // Cuts the statement's own closing/disclaimer block off the *whole*
        // document before it's ever split into chunks — see
        // truncateAtFooter's doc comment for why this runs once here
        // instead of as another per-chunk skip like
        // looksLikeNonTransactionSection below.
        let statementText = truncateAtFooter(statementText)

        var allEntries: [StatementLineItem] = []
        for chunk in chunkedByLines(statementText, maxCharacters: maxChunkCharacters, overlapCharacters: chunkOverlapCharacters) {
            // Skip the model call entirely for a chunk that's recognizably
            // a MAD/interest-calculation illustration or T&Cs/legal page —
            // see looksLikeNonTransactionSection's doc comment for why this
            // has to happen before the model ever sees the chunk, not just
            // via its own isGenuineTransaction judgment.
            guard !looksLikeNonTransactionSection(chunk) else { continue }

            let chunkEntries = await extractLineItemsWithRetry(chunk: chunk, instructions: instructions)
            // Two more independent gates before a row counts as real:
            //  1. The model's own "is this actually a transaction" gate —
            //     keeps fee-schedule/interest-table/reward-summary/T&Cs/
            //     illustration rows out even when a chunk mixes them with
            //     real transactions (or wasn't caught by the whole-chunk
            //     skip above).
            //  2. amountAppearsInSource — a deterministic backstop for the
            //     case the model's own judgment can't self-police: a chunk
            //     of pure boilerplate (no transaction data at all) can
            //     still make the model invent a plausible-looking row out
            //     of thin air and confidently mark it genuine — this
            //     catches that by requiring the row's amount to actually
            //     be printed somewhere in the text it supposedly came from.
            // Both discard before reconciliation, not just before display,
            // so a false/invented row never counts toward matched/unmatched.
            let genuineEntries = chunkEntries.filter {
                $0.isGenuineTransaction && amountAppearsInSource($0, chunk: chunk)
            }
            appendDeduping(genuineEntries, to: &allEntries)
        }
        return allEntries
    }

    /// Deterministic cut point for a statement's own closing block — "this
    /// is a computer/system generated statement," "does not require a
    /// signature," a customer-care/registered-office/grievance-officer
    /// block, and similar sign-off text that closes out virtually every
    /// bank/card statement. Real-world testing against an Axis Bank credit
    /// card statement showed exactly this kind of boilerplate leaking
    /// through as if it were transaction rows — the closing block sits in
    /// the *same* chunk as the tail end of the real transaction table
    /// rather than a chunk of its own, so looksLikeNonTransactionSection's
    /// whole-chunk skip below can't remove it without also losing the
    /// genuine rows sharing that chunk. Cutting the raw text here instead,
    /// once, before it's ever split into chunks, keeps everything before
    /// the marker and drops only what comes after.
    ///
    /// Cuts at the LAST matching line, not the first: the same closing
    /// phrase often repeats as a per-page footer on a multi-page statement,
    /// and cutting at the first occurrence would silently discard every
    /// later page's real transactions. Cutting at the last occurrence only
    /// ever removes the document's true trailing close, never anything
    /// before it — an earlier per-page repeat of the same phrase is left in
    /// place for looksLikeNonTransactionSection/isGenuineTransaction to
    /// handle downstream, same as before this existed.
    ///
    /// None of these markers are Axis-specific — the same closing-block
    /// shape is generic to virtually any issuer's statement, so this isn't
    /// scoped to Axis at all.
    private static let footerMarkers = [
        "this is a computer generated statement", "this is a system generated statement",
        "this is a computer-generated statement", "this is a system-generated statement",
        "does not require a signature",
        "please do not reply to this e-mail", "please do not reply to this email",
        "registered office", "regd. office", "regd office", "corporate office",
        "grievance redressal officer", "nodal officer",
    ]

    static func truncateAtFooter(_ statementText: String) -> String {
        let lines = statementText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let cutoff = lines.lastIndex(where: { line in
            let lowercased = line.lowercased()
            return footerMarkers.contains { lowercased.contains($0) }
        }) else { return statementText }
        return lines[..<cutoff].joined(separator: "\n")
    }

    /// Cheap, keyword-based screen applied *before* a chunk ever reaches
    /// the model — mirrors EmailTransactionParser.looksLikeTransactionAlert's
    /// role for email. Calibrated against a real ICICI/Amazon Pay statement
    /// during testing: its "how Minimum Amount Due is calculated" page is a
    /// worked EXAMPLE laid out with dates, line items ("EMI Principal",
    /// "Purchase on Oct 15, 2025"), and amounts that are genuinely printed
    /// on the page — exactly like a real transaction table, just fictional.
    /// Neither the instructions nor the model's own isGenuineTransaction
    /// judgment reliably told the two apart (the on-device model kept
    /// extracting the illustration's invented line items and marking them
    /// genuine), and since the amounts really are on the page,
    /// amountAppearsInSource can't catch it either — the only reliable
    /// signal left is the section's own header/framing language, checked
    /// here deterministically instead of left to the model to notice.
    ///
    /// Skipping the whole chunk (rather than trying to salvage a mixed
    /// chunk) is deliberately the blunter option: chunkedByLines' 2,500-
    /// character budget means a statement's actual transaction table and
    /// its legal/illustration pages essentially never land in the same
    /// chunk in practice, so the risk of losing a real row this way is low
    /// next to the alternative of the illustration's invented rows showing
    /// up as real spending.
    private static func looksLikeNonTransactionSection(_ chunk: String) -> Bool {
        let lowercased = chunk.lowercased()
        let markers = [
            "following illustration", "for illustration purposes",
            "scenario a:", "scenario b:", "minimum amount due calculation",
            "mad calculation", "interest calculation",
            "grievances redressal", "important information on your credit card",
            "terms and condition", "terms & condition", "great offers on your card",
            // Generic statement closing/disclaimer boilerplate — same
            // phrases truncateAtFooter looks for, kept here too as a
            // second, per-chunk line of defense for a closing block small
            // enough to land in its own chunk (truncateAtFooter only
            // catches the document's trailing close, not a shorter
            // disclaimer chunk sandwiched earlier). Deliberately doesn't
            // include a customer-care phone number line — that routinely
            // repeats in every page's header, transaction pages included,
            // so treating it as a whole-chunk skip signal risks losing
            // real rows rather than just the one boilerplate line.
            "computer generated statement", "system generated statement",
            "does not require a signature", "please do not reply to this",
            "registered office", "corporate office",
        ]
        return markers.contains { lowercased.contains($0) }
    }

    /// Normalizes out thousands separators, then checks every plausible
    /// printed form of `entry.amount` (two decimals, one decimal, and a
    /// bare integer when the amount has none) against the chunk text.
    /// Genuine rows the model actually read off the page pass this
    /// trivially, since the number is right there; a row invented whole
    /// cloth almost never happens to match a number already in the text.
    ///
    /// Matches are digit-boundary-aware (never a plain substring check) —
    /// amount 50 must not count as "found" just because the text contains
    /// 50000 or 150.00; the candidate has to appear as its own number.
    private static func amountAppearsInSource(_ entry: StatementLineItem, chunk: String) -> Bool {
        let normalizedChunk = chunk.replacingOccurrences(of: ",", with: "")
        let rounded = (entry.amount * 100).rounded() / 100
        var candidates: Set<String> = [
            String(format: "%.2f", rounded),
            String(format: "%.1f", rounded),
        ]
        if rounded == rounded.rounded() {
            candidates.insert(String(format: "%.0f", rounded))
        }
        return candidates.contains { candidate in
            let escaped = NSRegularExpression.escapedPattern(for: candidate)
            let pattern = "(?<!\\d)\(escaped)(?!\\d)"
            return normalizedChunk.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Splits `text` into whole-line chunks of at most `maxCharacters`,
    /// each (after the first) opening with the previous chunk's trailing
    /// `overlapCharacters` worth of lines repeated verbatim — chosen over a
    /// raw character split so a chunk boundary never lands mid-row.
    static func chunkedByLines(_ text: String, maxCharacters: Int, overlapCharacters: Int) -> [String] {
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
    static func splitInHalf(_ text: String) -> [String] {
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

    /// ±1 day — a statement's printed date and the actual transaction date
    /// Panam recorded commonly drift by a day (posting date vs. the date
    /// you logged it, timezone rounding, etc.).
    private static let dateToleranceDays = 1

    /// Compares each extracted line against `transactions`: same date
    /// (±1 day), same amount, the same debit/credit direction, and — only
    /// when the line names a card/account via last-4 — the same resolved
    /// account. A line with no last-4 is matched on date+amount+direction
    /// alone, same as the other conditions being sufficient when there's
    /// nothing more specific to check.
    ///
    /// A credit line that isn't already matched here doesn't automatically
    /// become plain "possibly missing income" — see candidate(for:
    /// accounts:transactions:), which runs it through
    /// EmailTransactionParser.matchRefund first, exactly like a credit
    /// alert email does, so a CR that's actually a refund for an existing
    /// debit gets reclassified before it's ever shown for review.
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
                unmatched.append(candidate(for: entry, accounts: accounts, transactions: transactions))
            }
        }
        return (matchedCount, unmatched)
    }

    private static func isMatched(_ entry: StatementLineItem, in transactions: [Transaction], accounts: [Account]) -> Bool {
        // ParsedTransaction.parseFlexibleDate, not a strict yyyy-MM-dd-only
        // parse — the model asked for ISO but real-world testing showed it
        // reliably echoing the statement's own dd/MM/yyyy dates instead
        // (see that function's doc comment), and a line whose date can't be
        // resolved at all can't be confidently matched either way.
        guard let entryDate = ParsedTransaction.parseFlexibleDate(entry.dateString) else { return false }
        let resolvedAccount = resolveAccount(entry.lastFourDigits, accounts: accounts)

        return transactions.contains { transaction in
            guard withinTolerance(transaction.date, entryDate) else { return false }
            guard amountsMatch(transaction.amount, entry.amount) else { return false }
            guard directionMatches(entry, transaction) else { return false }
            if let resolvedAccount {
                return transaction.account == resolvedAccount
            }
            return true
        }
    }

    /// A statement credit line should only count as already-matched
    /// against an income-like Transaction (income/interest/dividend/
    /// refund), and a debit line only against a non-income-like one —
    /// without this, a CR entry could spuriously "match" an unrelated
    /// expense Transaction that merely happens to share the same date,
    /// amount, and account, silently absorbing it into matchedCount and
    /// keeping it from ever reaching candidate(for:accounts:transactions:)'s
    /// refund-matching step below.
    private static func directionMatches(_ entry: StatementLineItem, _ transaction: Transaction) -> Bool {
        entry.isCredit == transaction.type.isIncomeLike
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
    /// line actually carries, and type set from entry.isCredit rather than
    /// always "expense". Feeds straight into the same
    /// AddEditTransactionView(prefill:) sheet every other entry point uses.
    ///
    /// A credit line is run through EmailTransactionParser.matchRefund
    /// against `transactions` before this returns — the exact same
    /// deterministic post-processing step a credit alert email goes
    /// through (see EmailFetchCoordinator's transaction-mail fetch) — so a
    /// CR that's really a refund for an existing debit is reclassified to
    /// .refund, with matchedRefundTransaction carried along, instead of
    /// surfacing as plain unmatched income.
    private static func candidate(
        for entry: StatementLineItem, accounts: [Account], transactions: [Transaction]
    ) -> StatementReconciliationCandidate {
        var parsed = ParsedTransaction(
            amount: entry.amount,
            type: entry.isCredit ? "income" : "expense",
            categoryName: nil,
            accountName: nil,
            note: entry.description,
            merchantName: entry.description,
            lastFourDigits: entry.lastFourDigits,
            resolvedDateString: entry.dateString,
            paymentMethodName: nil,
            isGenuineTransaction: true
        )

        var matchedRefundTransaction: Transaction?
        if entry.isCredit {
            let (reclassified, matched) = EmailTransactionParser.matchRefund(for: parsed, against: transactions)
            parsed = reclassified
            matchedRefundTransaction = matched
        }

        return StatementReconciliationCandidate(
            rawDescription: entry.description, parsed: parsed, matchedRefundTransaction: matchedRefundTransaction
        )
    }
}
