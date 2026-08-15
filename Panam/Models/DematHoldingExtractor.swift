//
//  DematHoldingExtractor.swift
//  Panam
//

import Foundation
import FoundationModels

// MARK: - Extraction schema

/// One holding line as printed on a demat/broker portfolio statement (e.g.
/// Upstox). Only the name and current value are extracted — the invested
/// amount is never taken from the statement at all; it already exists on
/// the matched Investment record (see Investment.investedValue), computed
/// from the app's own logged contributions/lumpsum entry, which is the only
/// invested figure Panam trusts. currentValueString is deliberately kept as
/// a raw string rather than Double — statement formatting for this column
/// varies enough (₹ symbols, thousands separators, parenthesized negatives)
/// that letting the model report exactly what's printed and parsing it
/// deterministically afterward (see DematHoldingExtractor.parseAmount) is
/// more robust than asking the model to also normalize it, the same
/// reasoning StatementLineItem's dateString takes for dates.
@Generable
struct DematHolding {
    @Guide(description: "The exact name of the stock/mutual fund/instrument as printed on the statement — e.g. \"RELIANCE INDUSTRIES LTD\" or \"HDFC Flexi Cap Fund\"")
    var instrumentName: String

    @Guide(description: "The current market value of this holding as of the statement date, exactly as printed on the statement (keep any currency symbols, commas, or decimals as printed — do not convert or normalize it)")
    var currentValueString: String

    @Guide(description: "Only true if this is a real holding row from the statement's actual portfolio/holdings table — a specific instrument name with its own current value. False for a portfolio summary/total row, a disclaimer, a header, a footer, or any other non-holding text, even if it contains numbers that look like amounts.")
    var isGenuineHolding: Bool
}

/// The model's full response for one section of a holdings statement — a
/// flat list, not a summary, same shape as StatementExtraction.
@Generable
struct DematHoldingExtraction {
    @Guide(description: "Every holding row found in this section of the statement, in the order they appear. Include every row — do not summarize, merge, or skip any of them, even if there are many.")
    var holdings: [DematHolding]
}

// MARK: - Review candidate

/// One extracted holding paired with its best-guess existing Investment
/// (nil if nothing matched closely enough to guess) and the extracted
/// current value, already parsed to Double for display and editing.
/// DematStatementsSheet shows every one of these for confirmation before
/// anything on Investment actually changes — see
/// DematHoldingExtractor.matchInvestment(for:in:) and
/// EmailFetchCoordinator.confirmDematMatch. currentValue is a var, not a
/// let: the review row lets it be corrected in place (OCR/extraction can
/// misread a digit) before it's ever written to Investment.currentValue.
struct DematHoldingReviewCandidate: Identifiable {
    let id = UUID()
    let holding: DematHolding
    var currentValue: Double?
    var suggestedInvestment: Investment?

    /// The matched Investment's own invested amount — a read-only reference
    /// for the review row, never edited here. Always the app's own
    /// Investment.investedValue (contributions/lumpsum Panam already knows
    /// about), never anything parsed from the statement — see DematHolding's
    /// doc comment.
    var investedAmount: Double? { suggestedInvestment?.investedValue }
}

enum DematHoldingExtractor {
    private static let instructions = """
        You will be given a section of the raw text extracted from a demat/ \
        broker portfolio or holdings statement PDF (e.g. Upstox) — possibly \
        the whole statement, possibly just one part of a longer one. Amounts \
        are in Indian rupees.

        Find every individual holding line in this section — this is \
        usually a table listing each stock, mutual fund, or other \
        instrument the customer holds, along with what it's currently \
        worth. Extract EVERY holding row in THIS section as its own entry \
        — do not summarize, do not report only a few examples, and do not \
        merge multiple holdings into one.

        Ignore rows that aren't individual holdings: statement headers, \
        column headers, portfolio total/summary rows, page footers, \
        disclaimers, and marketing text.

        Only extract rows from the actual holdings/portfolio table — each \
        with a specific instrument name and a current value. Do NOT \
        extract: the portfolio grand total, asset-allocation summary rows, \
        disclaimers/legal text, or promotional inserts, even if they \
        contain rupee amounts.

        A genuine holding row always names a specific instrument (a \
        company, a fund, a bond). A row with no instrument name — just a \
        label like "Total" or "Equity" — is a summary row, not a holding.

        Set isGenuineHolding to false for any row drawn from a summary/total \
        section instead of the real holdings table — false entries are \
        discarded, so when in doubt, still include the row but mark it \
        accordingly rather than omitting it outright.

        If this section contains no real holding rows at all, return an \
        empty list. Never invent a holding.

        The text may contain OCR/extraction noise — misaligned columns, odd \
        line breaks, stray whitespace — use your best judgment to recover \
        each row's real instrument name and current value.
        """

    // MARK: Extraction

    /// Same chunked-extraction shape as StatementReconciler.extractLineItems
    /// (reuses its chunking budget/helpers directly — see that type). This
    /// is genuinely new territory for Panam — holdings, not transactions —
    /// so treat the first real run against a real Upstox statement as a
    /// calibration pass, same as statement-line extraction needed.
    static func extractHoldings(from statementText: String) async throws -> [DematHolding] {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw StatementReconcilerError.modelUnavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw StatementReconcilerError.modelUnavailable("Turn on Apple Intelligence in Settings to extract holdings.")
        case .unavailable(.modelNotReady):
            throw StatementReconcilerError.modelUnavailable("The on-device model isn't ready yet. Try again in a bit.")
        case .unavailable:
            throw StatementReconcilerError.modelUnavailable("The on-device model is unavailable.")
        }

        var allHoldings: [DematHolding] = []
        for chunk in StatementReconciler.chunkedByLines(
            statementText,
            maxCharacters: StatementReconciler.maxChunkCharacters,
            overlapCharacters: StatementReconciler.chunkOverlapCharacters
        ) {
            let chunkHoldings = await extractHoldingsWithRetry(chunk: chunk)
            // Same two-gate discipline as StatementReconciler: the model's
            // own isGenuineHolding judgment, plus a deterministic backstop
            // (nameAppearsInSource) for the case a chunk of pure boilerplate
            // makes the model invent a plausible-looking row out of thin air.
            let genuine = chunkHoldings.filter { $0.isGenuineHolding && nameAppearsInSource($0, chunk: chunk) }
            appendDeduping(genuine, to: &allHoldings)
        }
        return allHoldings
    }

    private static func extractHoldingsWithRetry(chunk: String) async -> [DematHolding] {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: chunk, generating: DematHoldingExtraction.self)
            return response.content.holdings
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize(_) {
            guard chunk.count > StatementReconciler.minSplittableCharacters else { return [] }
            var holdings: [DematHolding] = []
            for half in StatementReconciler.splitInHalf(chunk) {
                holdings.append(contentsOf: await extractHoldingsWithRetry(chunk: half))
            }
            return holdings
        } catch {
            return []
        }
    }

    /// Mirrors StatementReconciler.amountAppearsInSource's role, adapted to
    /// a holding's defining feature being its name rather than a single
    /// amount (currentValueString is a loosely-formatted string, ill-suited
    /// to the same digit-boundary check).
    /// Checked as a case-insensitive substring on just the instrument's
    /// first word (when long enough to be distinctive) rather than the full
    /// name, so the model lightly trimming a trailing "LTD"/"LIMITED" —
    /// something it does in practice — doesn't fail a genuine row.
    private static func nameAppearsInSource(_ holding: DematHolding, chunk: String) -> Bool {
        let trimmed = holding.instrumentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        guard firstWord.count >= 3 else { return chunk.localizedCaseInsensitiveContains(trimmed) }
        return chunk.localizedCaseInsensitiveContains(firstWord)
    }

    /// Same near-boundary-repeat collapsing as StatementReconciler.
    /// appendDeduping, keyed on instrument name alone (a holdings statement
    /// lists each instrument once, unlike a transaction table where the
    /// same merchant can legitimately repeat) rather than a date+amount+
    /// description triple.
    private static func appendDeduping(_ newHoldings: [DematHolding], to aggregate: inout [DematHolding]) {
        for holding in newHoldings {
            let recentTail = aggregate.suffix(8)
            let isDuplicate = recentTail.contains {
                $0.instrumentName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(holding.instrumentName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
            if !isDuplicate { aggregate.append(holding) }
        }
    }

    // MARK: Amount parsing

    /// Permissive currency-string parser for currentValueString — strips
    /// everything but digits, a single decimal point, and a leading minus
    /// sign (currency symbols, thousands commas/spaces, "Rs.", any trailing
    /// suffix a statement adds). Returns nil for anything that doesn't
    /// leave at least one digit behind.
    static func parseAmount(_ raw: String) -> Double? {
        var cleaned = ""
        var seenDecimalPoint = false
        for (index, char) in raw.enumerated() {
            if char.isNumber {
                cleaned.append(char)
            } else if char == "." && !seenDecimalPoint {
                seenDecimalPoint = true
                cleaned.append(char)
            } else if char == "-" && index == 0 {
                cleaned.append(char)
            }
        }
        guard !cleaned.isEmpty, cleaned != "-" else { return nil }
        return Double(cleaned)
    }

    // MARK: Matching

    /// Loose substring match, either direction, case/whitespace-insensitive
    /// — the exact same tolerance EmailTransactionParser's merchantMatches
    /// uses for merchant names in refund detection, since a statement's
    /// instrument name ("RELIANCE INDUSTRIES LTD") and however the user
    /// named the Investment ("Reliance") are just as unlikely to match
    /// character-for-character.
    static func namesAreSimilar(_ a: String, _ b: String) -> Bool {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    /// Exact remembered mapping first (Investment.upstoxHoldingName) — this
    /// is what lets a holding auto-update silently on every statement after
    /// the first confirmed match, instead of asking again (see
    /// EmailFetchCoordinator.processDematRow). Falls back to the loose name
    /// match only when nothing's been remembered yet for this instrument.
    static func matchInvestment(for holding: DematHolding, in investments: [Investment]) -> Investment? {
        if let remembered = investments.first(where: { $0.upstoxHoldingName == holding.instrumentName }) {
            return remembered
        }
        return investments.first { namesAreSimilar($0.name, holding.instrumentName) }
    }
}
