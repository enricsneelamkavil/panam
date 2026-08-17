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

/// One extracted holding paired with whether nameAppearsInSource verified
/// it — the unit extractHoldings actually returns, instead of a bare
/// [DematHolding], so a name-verification failure can be surfaced to the
/// caller (see DematHoldingReviewCandidate.nameVerified) instead of being
/// discarded before it ever leaves this file.
struct DematHoldingExtractionResult {
    let holding: DematHolding
    let nameVerified: Bool
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

    /// False when this holding's own name doesn't turn up anywhere in the
    /// statement chunk it was extracted from (DematHoldingExtractor.
    /// nameAppearsInSource) — the same backstop StatementReconciler's
    /// amountAppearsInSource applies to invented transaction rows, adapted
    /// to a holding's defining feature being its name. Previously a row
    /// failing this was silently dropped outright: a real Upstox statement
    /// had a genuine HDFC holding (₹52,889.66) come back from the model as
    /// "RELIANCE INDUSTRIES LTD" — a name that appears nowhere in the
    /// source — and the row vanished with no trace anywhere in the review
    /// screen. Surfacing it instead, flagged, means a mangled-but-real
    /// holding is at least visible and can be caught/fixed manually, rather
    /// than silently missing — the same never-silently-fail principle
    /// StatementReconciler's date parsing already follows.
    var nameVerified: Bool = true

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

        IMPORTANT — this section may ALSO contain an entirely different \
        table that is NOT the holdings table: a transaction/ledger history \
        (columns like Date, Description, Buy/Cr, Sell/Dr, Balance) that \
        shows a running BALANCE for each instrument. That Balance column is \
        a unit/quantity count, not a rupee value — never use it as \
        currentValueString, even though it's a plausible-looking decimal \
        number sitting right next to the instrument's name. The real \
        holdings table is usually titled something like "Holding \
        Valuation" or "Portfolio Valuation" and has its own columns — \
        typically Current Bal, Free Bal, Rate, and Value. Of those, ONLY \
        the Value column (the last one, usually the largest number on the \
        row — quantity multiplied by rate) is the current value. Rate is \
        the per-unit/per-share price, not the holding's total value — do \
        not use it either. If both a ledger table and a holdings-valuation \
        table are present, always extract currentValueString from the \
        holdings-valuation table's Value column, never from the ledger.

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

    /// A demat/broker statement can interleave two structurally different
    /// tables once flattened to plain text: a transaction/ledger history
    /// (its own running unit-BALANCE column, not a rupee value) and the
    /// actual holdings table, titled something like "Holding Valuation as \
    /// On <date>", whose Value column is the real current value. Confirmed
    /// against a real Upstox statement: with both tables in view and no
    /// structural markers left after text-extraction, the model latched
    /// onto the ledger's Closing Balance figure (a unit count) — or the
    /// valuation table's own Rate column — mistaking either for the current
    /// value, for every holding that had a ledger entry. Cutting the raw
    /// text at the valuation table's own header, once, before it's ever
    /// chunked or shown to the model, removes that ambiguity outright
    /// rather than leaving it to instructions alone to resolve — same
    /// pre-truncation philosophy as StatementReconciler.truncateAtFooter,
    /// just cutting away the *leading* section instead of a trailing one.
    ///
    /// Cuts at the FIRST matching line (truncateAtFooter cuts at the last):
    /// a valuation table only ever prints this header once, at its start —
    /// there's no per-page repeat of it to skip past the way a footer
    /// disclaimer can repeat on every page.
    ///
    /// If no such header is found (statement format varies enough that this
    /// can't be assumed universal), the text is returned unchanged and the
    /// instructions' own explicit ledger-vs-valuation-table warning is the
    /// only remaining defense.
    private static let holdingsValuationMarkers = [
        "holding valuation as on", "holding valuation as of",
        "holdings valuation as on", "holdings valuation as of",
        "portfolio valuation as on", "portfolio valuation as of",
    ]

    static func isolateValuationSection(_ statementText: String) -> String {
        let lines = statementText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let cutoff = lines.firstIndex(where: { line in
            let lowercased = line.lowercased()
            return holdingsValuationMarkers.contains { lowercased.contains($0) }
        }) else { return statementText }
        return lines[cutoff...].joined(separator: "\n")
    }

    /// A row extracted deterministically off the valuation table's own
    /// fixed layout — see parseValuationRows — rather than picked by the
    /// model among several unlabeled numbers on the line.
    private struct DeterministicValuationRow {
        let instrumentName: String
        let currentValueString: String
    }

    /// Isolating the valuation table (isolateValuationSection) removes the
    /// ledger-vs-valuation table confusion, but not a second, narrower
    /// ambiguity: confirmed against a real Upstox statement, even the
    /// isolated table's own column HEADERS come out scrambled by
    /// PDFKit's text extraction — "Company Name" and the real "Value"
    /// header end up detached onto a separate line, while the header line
    /// actually adjacent to the data never mentions "Value" at all. With
    /// no readable label next to it, the model kept grabbing Current Bal
    /// or Rate instead — both plausible-looking decimals sitting closer to
    /// the name — even after being told explicitly, in instructions, which
    /// column to use.
    ///
    /// This sidesteps the model for the number entirely on rows shaped
    /// like Upstox's: whatever the name contains, a genuine row's line
    /// always ends in exactly five tokens, in this fixed order —
    /// CurrentBal, FreeBal, a DD/MM/YYYY Value Date, Rate, Value. Matching
    /// that shape from the *right* end of the line (rather than trying to
    /// label columns from the left, where the name's own length varies)
    /// finds the real Value column unambiguously — it even resolves a
    /// bond like "MFL 10.00 19052031" correctly, its own coupon rate and
    /// maturity code baked right into the printed name, because there's
    /// only one point in the line where the fixed trailing shape actually
    /// fits once the regex backtracks past those embedded numbers.
    ///
    /// Requires a genuine ISIN (India's standard 12-character alphanumeric
    /// security identifier) somewhere before that trailing shape — every
    /// real holding row has one, and requiring it keeps this from
    /// misfiring on some unrelated numeric line that happens to end the
    /// same way. A line without one, or that doesn't fit the shape at all
    /// (a different broker's layout), is simply left alone — this is a
    /// targeted override on top of the model's own extraction wherever it
    /// applies, not a replacement for it.
    private static let valuationRowPattern = #"^(.+?)\s+([\d,]+\.?\d*)\s+([\d,]+\.?\d*)\s+(\d{2}/\d{2}/\d{4})\s+([\d,]+\.?\d*)\s+([\d,]+\.?\d*)\s*$"#
    private static let isinPattern = #"\b[A-Z]{2}[A-Z0-9]{9}\d\b"#
    private static let bareISINPattern = #"^[A-Z]{2}[A-Z0-9]{9}\d$"#

    /// True when a holding's entire instrumentName is nothing but an ISIN
    /// code — never a real instrument name a statement would actually
    /// print, so a "holding" shaped like this is a parsing artifact, not
    /// a genuine row (see its call site's doc comment for how this shows
    /// up in practice).
    private static func isBareISIN(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: bareISINPattern) else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return regex.firstMatch(in: trimmed, range: range) != nil
    }

    private static func parseValuationRows(from text: String) -> [DeterministicValuationRow] {
        guard let rowRegex = try? NSRegularExpression(pattern: valuationRowPattern),
              let isinRegex = try? NSRegularExpression(pattern: isinPattern)
        else { return [] }

        var rows: [DeterministicValuationRow] = []
        for substring in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(substring)
            let lineRange = NSRange(line.startIndex..., in: line)
            guard let match = rowRegex.firstMatch(in: line, range: lineRange),
                  let namePrefixRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 6), in: line)
            else { continue }
            let namePrefix = String(line[namePrefixRange])

            // The prefix may still carry scrambled header text ahead of
            // the real row (see this function's doc comment) — anchor on
            // the LAST ISIN in it (the row's own) and take only what
            // follows as the instrument name.
            let prefixRange = NSRange(namePrefix.startIndex..., in: namePrefix)
            guard let isinMatch = isinRegex.matches(in: namePrefix, range: prefixRange).last,
                  let isinRange = Range(isinMatch.range, in: namePrefix)
            else { continue }

            let name = namePrefix[isinRange.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            rows.append(DeterministicValuationRow(instrumentName: name, currentValueString: String(line[valueRange])))
        }
        return rows
    }

    /// Same chunked-extraction shape as StatementReconciler.extractLineItems
    /// (reuses its chunking budget/helpers directly — see that type). This
    /// is genuinely new territory for Panam — holdings, not transactions —
    /// so treat the first real run against a real Upstox statement as a
    /// calibration pass, same as statement-line extraction needed.
    static func extractHoldings(from statementText: String) async throws -> [DematHoldingExtractionResult] {
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

        let isolatedText = isolateValuationSection(statementText)
        let deterministicRows = parseValuationRows(from: isolatedText)

        var allHoldings: [DematHoldingExtractionResult] = []
        for chunk in StatementReconciler.chunkedByLines(
            isolatedText,
            maxCharacters: StatementReconciler.maxChunkCharacters,
            overlapCharacters: StatementReconciler.chunkOverlapCharacters
        ) {
            let chunkHoldings = await extractHoldingsWithRetry(chunk: chunk)
            // isGenuineHolding is still a hard discard — the model's own
            // judgment that a row is a summary/total/disclaimer line, not a
            // holding at all, is trustworthy enough to drop outright (see
            // its @Guide). nameAppearsInSource is different: it's a
            // deterministic backstop against the model inventing/mangling a
            // name, and a row failing it might still be a real holding
            // (see DematHoldingReviewCandidate.nameVerified) — so it's
            // tagged, not dropped, and left for the review screen to flag.
            //
            // isBareISIN is a third, hard discard: confirmed against a
            // real Upstox statement, once the section's instructions
            // started calling out "ISIN Code" by name (to fix the Rate/
            // Current-Bal column confusion above), the model started
            // splitting a genuine row into TWO holdings — one correct, and
            // a spurious second one naming the row's own ISIN code as if
            // it were a separate instrument, with a garbled multi-token
            // currentValueString (e.g. "31/07/2026 160.75 52,889.66" —
            // several columns run together, not any single figure) that
            // parseAmount can't meaningfully parse either. A holding whose
            // "name" is nothing but its own ISIN was never a real
            // instrument to begin with, so this is dropped outright rather
            // than merely flagged.
            let genuine = chunkHoldings.filter { $0.isGenuineHolding && !isBareISIN($0.instrumentName) }
            let tagged = genuine.map { holding -> DematHoldingExtractionResult in
                var holding = holding
                let verified = nameAppearsInSource(holding, chunk: chunk)
                // A deterministic row read directly off the statement's
                // own fixed Value-column shape (see parseValuationRows) is
                // far more trustworthy than a number the model picked
                // among several unlabeled trailing figures — override with
                // it, and treat the name as verified outright, whenever
                // the two agree on which instrument this is.
                if let deterministic = deterministicRows.first(where: { namesAreSimilar($0.instrumentName, holding.instrumentName) }) {
                    holding.currentValueString = deterministic.currentValueString
                    return DematHoldingExtractionResult(holding: holding, nameVerified: true)
                }
                return DematHoldingExtractionResult(holding: holding, nameVerified: verified)
            }
            appendDeduping(tagged, to: &allHoldings)
        }

        // Defense in depth: a deterministic row with no corresponding
        // model holding at all — the model dropped or badly mangled the
        // name entirely — still gets surfaced, fully trusted, since it was
        // read directly off the statement's own row shape rather than
        // guessed by the model.
        for row in deterministicRows where !allHoldings.contains(where: { namesAreSimilar($0.holding.instrumentName, row.instrumentName) }) {
            let holding = DematHolding(instrumentName: row.instrumentName, currentValueString: row.currentValueString, isGenuineHolding: true)
            allHoldings.append(DematHoldingExtractionResult(holding: holding, nameVerified: true))
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
    private static func appendDeduping(_ newHoldings: [DematHoldingExtractionResult], to aggregate: inout [DematHoldingExtractionResult]) {
        for result in newHoldings {
            let recentTail = aggregate.suffix(8)
            let isDuplicate = recentTail.contains {
                $0.holding.instrumentName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(result.holding.instrumentName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
            if !isDuplicate { aggregate.append(result) }
        }
    }

    // MARK: Amount parsing

    /// Permissive currency-string parser for currentValueString. Rather than
    /// scanning char-by-char from index 0 (the previous approach — see git
    /// history), this jumps straight to the numeral: everything before the
    /// first digit (currency symbols, "Rs.", whitespace) and after the last
    /// digit (currency codes, "Cr", a trailing "%") is discarded wholesale,
    /// so a prefix's own punctuation can never be accident-parsed as part of
    /// the number. That matters concretely: "Rs. 52,000" used to parse as
    /// 0.52 — the "." in "Rs." got taken as *the* decimal point, appended
    /// before any digit had even been seen, silently collapsing a 5-figure
    /// rupee amount to sub-1. That bug, combined with a small invested
    /// amount, is what produced a holding showing an unreal ~-100% return.
    ///
    /// A "." only counts as a genuine decimal point when it's the *last*
    /// one in the numeral and exactly 1-2 digits follow it to the end — a
    /// real fractional amount like "52000.50" or "52000.5". Any other "."
    /// (a thousands/lakh-style separator, e.g. "52.000", or a stray
    /// artifact) is stripped like a comma. Indian lakh-style grouping
    /// ("5,2,000") already works fine either way, since commas are dropped
    /// unconditionally regardless of where they fall.
    ///
    /// Accounting-style parenthesized negatives ("(52,000)") are honored as
    /// -52000 — a deliberate choice: parenthesized negatives are a real,
    /// if uncommon, convention on financial statements, and silently
    /// dropping the parens (the previous behavior) loses that sign instead
    /// of just ignoring decorative punctuation.
    ///
    /// Returns nil for anything that doesn't leave at least one digit
    /// behind.
    static func parseAmount(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isParenthesizedNegative = trimmed.hasPrefix("(") && trimmed.contains(")")

        guard let firstDigit = trimmed.firstIndex(where: { $0.isNumber }),
              let lastDigit = trimmed.lastIndex(where: { $0.isNumber })
        else { return nil }

        let hasLeadingMinus = trimmed[trimmed.startIndex..<firstDigit].contains("-")
        let core = trimmed[firstDigit...lastDigit]

        let integerPart: Substring
        let fractionalPart: Substring
        if let lastDot = core.lastIndex(of: "."), (1...2).contains(core.distance(from: core.index(after: lastDot), to: core.endIndex)) {
            integerPart = core[core.startIndex..<lastDot]
            fractionalPart = core[core.index(after: lastDot)...]
        } else {
            integerPart = core
            fractionalPart = ""
        }

        let digits = integerPart.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        let cleaned = fractionalPart.isEmpty ? digits : "\(digits).\(fractionalPart)"

        guard let value = Double(cleaned) else { return nil }
        return (isParenthesizedNegative || hasLeadingMinus) ? -value : value
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
