import Foundation
import FoundationModels
import SwiftData

enum EmailParsingError: LocalizedError {
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): reason
        }
    }
}

/// The model's full response for one transaction-alert email — a flat
/// list, not a single transaction, mirroring StatementExtraction's array
/// pattern: a daily/weekly digest from a card issuer can legitimately
/// bundle several separate charges into one email, and wrapping the array
/// in its own @Generable type (rather than generating [ParsedTransaction]
/// directly) is what lets LanguageModelSession target a list-of-many-items
/// response at all — same reasoning as StatementExtraction/
/// DematHoldingExtraction.
@Generable
struct ParsedTransactionBatch {
    @Guide(description: "Every distinct transaction alert found in this email, in the order they appear. Most transaction emails report exactly one transaction — extract exactly one entry in that case. A digest-style email can bundle several separate charges into one message; extract every one of them as its own entry, never merged, summarized, or reduced to just the first or largest.")
    var entries: [ParsedTransaction]
}

enum EmailTransactionParser {
    /// Parses a bank/card transaction-alert email into one or more
    /// structured transactions using the on-device foundation model — same
    /// pattern as VoiceTransactionParser, fed email text instead of a
    /// speech transcript, except an email can legitimately contain several
    /// distinct alerts (a daily digest), where a voice command or a single
    /// receipt scan can't.
    ///
    /// isGenuineTransaction is applied per entry right here, same as
    /// StatementReconciler.extractLineItems/DematHoldingExtractor.
    /// extractHoldings filtering their own multi-item results before
    /// returning — a bundled digest's one promotional line shouldn't sink
    /// the other genuine entries in the same email, and shouldn't quietly
    /// show up as a candidate either. An empty result means either no
    /// transaction was found or every entry failed that gate; either way
    /// the caller (EmailFetchCoordinator) treats it as "nothing to show,"
    /// same as the single-transaction version's isGenuineTransaction==false
    /// case always did.
    static func parse(emailBody: String,
                      subject: String,
                      categories: [Category],
                      accounts: [Account]) async throws -> [ParsedTransaction] {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw EmailParsingError.modelUnavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw EmailParsingError.modelUnavailable("Turn on Apple Intelligence in Settings to use email import.")
        case .unavailable(.modelNotReady):
            throw EmailParsingError.modelUnavailable("The on-device model isn't ready yet. Try again in a bit.")
        case .unavailable:
            throw EmailParsingError.modelUnavailable("The on-device model is unavailable.")
        }

        let categoryNames = categories.map(\.name).joined(separator: ", ")
        let accountNames = accounts.map(\.name).joined(separator: ", ")

        let instructions = """
            Parse a bank or card transaction alert email into one or more \
            financial transactions. Amounts are in Indian rupees. The \
            email's subject line is: "\(subject)".

            This email may contain one or more separate transaction alerts \
            (e.g. a daily digest from a card issuer listing several \
            charges). Extract every distinct transaction as its own entry \
            — do not merge them into one, do not summarize, do not pick \
            only the first or largest. Most emails report exactly one \
            transaction; extract exactly one entry in that case.

            For each entry's categoryName, choose the closest match from \
            exactly these category names, or leave it nil if none fits: \
            \(categoryNames).

            For each entry's accountName, choose the closest match from \
            exactly these account names, or leave it nil if none fits: \
            \(accountNames). Bank/card alert emails usually name the \
            account (e.g. "HDFC Bank Card ending 1234") — match it to the \
            closest account name above.

            Never invent a category or account name that is not in those \
            lists — return the chosen names exactly as written above.

            For each entry: if it reports a debit/spend/payment, type is \
            "expense"; if it reports a credit/refund/salary, type is \
            "income".

            Set each entry's isGenuineTransaction to true only when it \
            reports one specific debit or credit that has already happened \
            to a specific account. Set it to false for a promotional \
            offer, a fee-structure/rate notice, a terms-and-conditions or \
            policy update, a newsletter, or any other general notice — \
            even one that mentions rupee amounts — judged independently \
            for each entry.
            """

        // The overwhelming common case: a single alert email fits in one
        // chunk (chunkedByLines returns just the one), so this runs the
        // model directly and lets a real failure throw straight out to the
        // caller — the exact single-shot behavior this function always
        // had, and the reason parseWithRetry's error-swallowing (built for
        // a multi-chunk statement/holdings document, where one bad section
        // shouldn't sink the rest) is deliberately NOT used for this,
        // typical, path: EmailFetchCoordinator surfaces a genuine failure
        // as candidate.parseError, and silently swallowing it here would
        // make that email's alert vanish instead.
        let chunks = StatementReconciler.chunkedByLines(
            emailBody, maxCharacters: StatementReconciler.maxChunkCharacters, overlapCharacters: StatementReconciler.chunkOverlapCharacters
        )
        guard chunks.count > 1 else {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: emailBody, generating: ParsedTransactionBatch.self)
                return response.content.entries.filter(\.isGenuineTransaction)
            } catch let error as LanguageModelError {
                if let fallback = fallbackIfSafetyRefusal(error, emailBody: emailBody, subject: subject) {
                    return [fallback]
                }
                throw error
            }
        }

        // Only reached for an email long enough to actually risk
        // LanguageModelError.contextSizeExceeded — the same risk a
        // multi-page statement runs, just far rarer for a single email
        // (an unusually large digest). Reuses StatementReconciler's own
        // chunking budget/helpers directly rather than duplicating them —
        // DematHoldingExtractor already does the same for the identical
        // reason (see StatementReconciler.maxChunkCharacters' doc comment).
        var allEntries: [ParsedTransaction] = []
        for chunk in chunks {
            let chunkEntries = await parseWithRetry(chunk: chunk, instructions: instructions, subject: subject)
            appendDeduping(chunkEntries.filter(\.isGenuineTransaction), to: &allEntries)
        }
        return allEntries
    }

    /// Runs one chunk through the model, halving and retrying on
    /// LanguageModelError.contextSizeExceeded — same shape as
    /// StatementReconciler.extractLineItemsWithRetry/DematHoldingExtractor.
    /// extractHoldingsWithRetry, kept as its own small copy rather than a
    /// shared generic (each wraps a different @Generable response type)
    /// exactly like those two already are relative to each other. Only
    /// ever reached for the rare multi-chunk email — see parse(_:)'s
    /// single-chunk fast path above for why swallowing an error here is
    /// fine in this context but wouldn't be for the common case.
    private static func parseWithRetry(chunk: String, instructions: String, subject: String) async -> [ParsedTransaction] {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: chunk, generating: ParsedTransactionBatch.self)
            return response.content.entries
        } catch LanguageModelError.contextSizeExceeded(_) {
            guard chunk.count > StatementReconciler.minSplittableCharacters else { return [] }
            var entries: [ParsedTransaction] = []
            for half in StatementReconciler.splitInHalf(chunk) {
                entries.append(contentsOf: await parseWithRetry(chunk: half, instructions: instructions, subject: subject))
            }
            return entries
        } catch let error as LanguageModelError {
            // Same safety-refusal fallback as the single-chunk path (see
            // fallbackIfSafetyRefusal's doc comment) — a guardrail-refused
            // chunk would otherwise just vanish into this function's
            // ordinary swallow-everything-else `catch` below, silently
            // dropping a real transaction from a digest email instead of
            // recovering it deterministically.
            if let fallback = fallbackIfSafetyRefusal(error, emailBody: chunk, subject: subject) {
                return [fallback]
            }
            return []
        } catch {
            return []
        }
    }

    /// Recovers from the on-device model refusing to generate anything at
    /// all for safety reasons — LanguageModelError.guardrailViolation or
    /// .refusal, both surfaced to the user as "Detected content likely to
    /// be unsafe" — by falling back to DeterministicEmailParser's regex/
    /// NSDataDetector extraction instead of losing the email entirely.
    ///
    /// Real-world testing against actual ICICI, HDFC, and RBL alert emails
    /// showed the on-device safety guardrail refusing every one of them —
    /// not because of any one excisable phrase (a fraud-report footer, a
    /// phone number, a masked card number, and even the bare transaction
    /// sentence alone all independently triggered it in isolation testing)
    /// but, best guess, because the generic "<card> has been used for a
    /// transaction of <amount>" notification phrasing real bank alerts use
    /// is indistinguishable to the classifier from a phishing message
    /// impersonating a bank. That means no amount of trimming the input
    /// text reliably avoids the refusal — the trigger looks to be the
    /// genuine transaction sentence itself, not anything around it — so
    /// recovering the transaction has to happen on the Swift side instead
    /// of by further prompting the model.
    ///
    /// Deliberately only intercepts these two specific safety-refusal
    /// cases, never any other LanguageModelError (a real parse failure like
    /// .decodingFailure or .unsupportedGuide still throws straight out to
    /// the caller exactly as before) — DeterministicEmailParser is a
    /// narrower, dumber extractor than the model, so reaching for it for
    /// anything other than "the model point-blank refused to even try"
    /// would trade the model's real extraction for a worse one.
    ///
    /// Returns nil (letting the original error propagate) when
    /// DeterministicEmailParser itself can't confidently find both an
    /// amount and a date — the caller still needs to see a genuine
    /// failure state in that case (EmailFetchCoordinator's existing
    /// parseError candidate), never a silently empty result.
    private static func fallbackIfSafetyRefusal(
        _ error: LanguageModelError, emailBody: String, subject: String
    ) -> ParsedTransaction? {
        switch error {
        case .guardrailViolation, .refusal:
            return DeterministicEmailParser.extract(emailBody: emailBody, subject: subject)
        default:
            return nil
        }
    }

    /// How far back to look for an overlap-caused repeat when merging a
    /// chunk's entries into the running list — mirrors StatementReconciler.
    /// appendDeduping's dedupLookback, scaled down for how few entries a
    /// multi-chunk *email* realistically produces versus a multi-page
    /// statement.
    private static let dedupLookback = 4

    /// Same near-boundary-repeat collapsing as StatementReconciler.
    /// appendDeduping, keyed on amount+date+merchant (ParsedTransaction has
    /// no isLikelyDuplicate of its own — StatementLineItem/DematHolding
    /// both declare theirs on the @Generable type itself since only their
    /// own extractor ever needs it; ParsedTransaction is shared by Voice/
    /// Receipt/Email/Statement parsing, so this stays local to the one
    /// caller that actually chunks its input).
    private static func appendDeduping(_ newEntries: [ParsedTransaction], to aggregate: inout [ParsedTransaction]) {
        for entry in newEntries {
            let recentTail = aggregate.suffix(dedupLookback)
            let isDuplicate = recentTail.contains {
                abs($0.amount - entry.amount) < 0.01
                    && $0.resolvedDateString == entry.resolvedDateString
                    && ($0.merchantName ?? "").caseInsensitiveCompare(entry.merchantName ?? "") == .orderedSame
            }
            if !isDuplicate { aggregate.append(entry) }
        }
    }
}

// MARK: - Pre-filter

extension EmailTransactionParser {
    /// Cheap keyword/structure screen applied *before* an email ever reaches
    /// the model — a bank's own mail stream is full of promotional offers,
    /// T&Cs/policy updates, and fee-schedule notices that share the model's
    /// vocabulary ("credited", "your card", rupee amounts) closely enough
    /// that leaving rejection entirely to isGenuineTransaction still let a
    /// meaningful share through as bogus candidates. This doesn't have to be
    /// exhaustive — anything that slips past still has to clear
    /// isGenuineTransaction downstream — it only has to cut the obvious
    /// non-candidates before they cost a model call.
    ///
    /// Requires: a transaction verb ("debited", "spent", …), a specific
    /// currency amount, no more than a handful of distinct amounts (a real
    /// alert cites the transaction amount plus maybe a running balance; a
    /// fee-schedule table or a multi-tier promo lists many), and none of the
    /// stock promotional/T&Cs/newsletter phrases.
    static func looksLikeTransactionAlert(emailBody: String, subject: String) -> Bool {
        let combined = (subject + " " + emailBody).lowercased()

        let transactionVerbs = [
            "debited", "credited", "spent", "withdrawn", "paid", "purchase of",
            "payment of", "transferred", "transaction of", "charged",
        ]
        guard transactionVerbs.contains(where: combined.contains) else { return false }

        let amounts = currencyAmounts(in: combined)
        guard !amounts.isEmpty else { return false }
        // A single alert names the transaction amount and, at most, a
        // running/available balance alongside it — a fee schedule or a
        // multi-tier offer lists many unrelated amounts instead.
        guard Set(amounts).count <= 4 else { return false }

        // Deliberately doesn't include generic footer boilerplate like
        // "click here," "know more," or "unsubscribe" — a genuine debit/
        // credit alert's own footer routinely carries an opt-out/
        // unsubscribe link as standard compliance boilerplate (confirmed
        // against a real SBI Card PhonePe alert, which was being rejected
        // here despite being a genuine transaction) alongside "view
        // details"/"report this transaction" phrasing, so those
        // false-positived on real transaction mail during testing against
        // a live inbox. Only phrases that are close to exclusively
        // promotional/T&Cs belong here.
        let promotionalTells = [
            "terms and conditions have been updated", "revised terms",
            "fee schedule", "limited period offer",
            "t&c apply", "tnc apply", "t&cs apply", "we've updated our", "we have updated our",
            "policy update", "new rates effective", "newsletter", "special offer",
            "offer valid", "cashback offer", "win rewards", "unlock rewards",
        ]
        guard !promotionalTells.contains(where: combined.contains) else { return false }

        return true
    }

    /// Matches "Rs. 1,234.56", "INR 500", "₹99" — same amount shapes bank
    /// alert emails actually use. Only used to count how many distinct
    /// amounts an email cites, not to extract the transaction amount itself
    /// (ParsedTransaction.amount is still the model's job).
    private static func currencyAmounts(in text: String) -> [String] {
        let pattern = #"(?:rs\.?|inr|₹)\s?[\d,]+(?:\.\d{1,2})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}

// MARK: - Refund matching

extension EmailTransactionParser {
    /// A window generous enough to cover slow bank/merchant refund
    /// processing (a week or two is typical) without reaching back so far
    /// it starts matching unrelated purchases.
    private static let refundWindowDays = 30

    /// After the model parses a candidate as a credit ("income"), checks
    /// whether it's actually a refund for a specific earlier expense on
    /// file — same/similar merchant (or, failing that, the credit's own
    /// wording explicitly reading as a reversal/refund — see
    /// looksLikeReversalOrRefund), within refundWindowDays, amount no
    /// larger than the original debit, and not already claimed by another
    /// refund — and if one is found, reclassifies the candidate as
    /// .refund with that expense's category defaulted in (still editable
    /// before import, like any other field). Returns the unmatched
    /// original `parsed` and `nil` if nothing qualifies. Called for every
    /// credit candidate regardless of source — a parsed credit alert email
    /// and a credit ("Cr") line item StatementReconciler pulled off a PDF
    /// statement both funnel through this same check (see
    /// StatementReconciler.candidate(for:accounts:transactions:)).
    ///
    /// Deterministic Swift-side post-processing, not part of the model's
    /// own instructions: matching requires searching existing Transaction
    /// records the model is never shown, so this always runs as a separate
    /// step after parse(_:), never in place of it.
    static func matchRefund(
        for parsed: ParsedTransaction, against transactions: [Transaction]
    ) -> (parsed: ParsedTransaction, matchedTransaction: Transaction?) {
        guard parsed.type.lowercased() == "income" else { return (parsed, nil) }

        // A debit that's already the refundedTransaction of some existing
        // refund has already been "claimed" — don't offer it again for a
        // second, unrelated credit that happens to fit the same window.
        let alreadyMatchedDebitIDs = Set(transactions.compactMap { $0.refundedTransaction?.persistentModelID })
        let creditDate = parsed.resolvedDate

        let candidates = transactions.filter { debit in
            debit.type.isExpenseLike
                && !debit.isExcludedFromFlow
                && !alreadyMatchedDebitIDs.contains(debit.persistentModelID)
                && parsed.amount <= debit.amount + 0.01
                && withinRefundWindow(debitDate: debit.date, creditDate: creditDate)
                // Ordinary merchant-name matching first; if that finds
                // nothing at all, fall back to treating every amount/window-
                // eligible debit as a candidate purely because the credit's
                // own wording explicitly says it's a reversal/refund — see
                // looksLikeReversalOrRefund's doc comment for why the name
                // check alone isn't enough for every issuer's wording.
                && (merchantMatches(parsed.merchantName, debit) || looksLikeReversalOrRefund(parsed.merchantName))
        }

        // Prefer the closest amount (a partial refund's fee gap should
        // still favor the debit it actually came from over a coincidentally
        // similar one), then the most recent debit as a final tiebreaker.
        guard let matched = candidates.min(by: { lhs, rhs in
            let lhsGap = lhs.amount - parsed.amount
            let rhsGap = rhs.amount - parsed.amount
            if abs(lhsGap - rhsGap) > 0.01 { return lhsGap < rhsGap }
            return lhs.date > rhs.date
        }) else {
            return (parsed, nil)
        }

        var reclassified = parsed
        reclassified.type = "refund"
        reclassified.categoryName = matched.category?.name
        return (reclassified, matched)
    }

    private static func withinRefundWindow(debitDate: Date, creditDate: Date) -> Bool {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: debitDate),
            to: calendar.startOfDay(for: creditDate)
        ).day ?? Int.max
        // A refund can't predate its own purchase, but a same-day pair
        // (days == 0) is common enough (instant/near-instant refunds) to allow.
        return days >= 0 && days <= refundWindowDays
    }

    /// Checks the credit's merchant guess against the debit's merchant name
    /// first, falling back to the debit's note — bank alert merchant names
    /// rarely match character-for-character ("AMAZON PAY INDIA" vs.
    /// "Amazon"), so this is deliberately a loose either-direction
    /// substring check rather than an exact-match comparison.
    private static func merchantMatches(_ creditMerchant: String?, _ debit: Transaction) -> Bool {
        guard let creditMerchant = normalized(creditMerchant) else { return false }
        if let debitMerchant = normalized(debit.merchantName), namesAreSimilar(creditMerchant, debitMerchant) {
            return true
        }
        guard let debitNote = normalized(debit.note) else { return false }
        return namesAreSimilar(creditMerchant, debitNote)
    }

    /// Fallback signal for matchRefund's candidate filter, checked only
    /// when the ordinary merchant-name check above found nothing: some
    /// issuers' credit line-item wording drops the original merchant name
    /// entirely in favor of generic reversal language — e.g. a statement
    /// line reading "REVERSAL OF TXN DT 12/07" or "CHARGEBACK ADJ" instead
    /// of repeating "AMAZON PAY INDIA" the way a "REFUND-AMAZON PAY INDIA"
    /// line would (that case is already covered by merchantMatches' loose
    /// substring check — the merchant name is still in there, just with a
    /// prefix). When the merchant name is genuinely gone, the credit's own
    /// explicit "this is a reversal/refund" wording is itself a strong
    /// enough signal to widen the candidate pool to every amount/window-
    /// eligible debit, rather than require a name match that can't
    /// possibly succeed.
    private static let reversalKeywords = ["reversal", "reversed", "refund", "chargeback", "charge back"]

    private static func looksLikeReversalOrRefund(_ description: String?) -> Bool {
        guard let description = normalized(description) else { return false }
        return reversalKeywords.contains { description.contains($0) }
    }

    private static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func namesAreSimilar(_ a: String, _ b: String) -> Bool {
        a.contains(b) || b.contains(a)
    }
}
