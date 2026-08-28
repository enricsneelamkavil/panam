//
//  DeterministicEmailParser.swift
//  Panam
//

import Foundation

/// Regex/NSDataDetector-based fallback for a bank transaction-alert email,
/// used only when the on-device model refuses to generate a response for
/// safety reasons — see EmailTransactionParser.fallbackIfSafetyRefusal's
/// doc comment for why that happens even for a completely ordinary alert.
/// Never used on the ordinary success path: the model's own extraction is
/// far richer (category/account matching against the user's real data,
/// genuine-vs-promotional judgment, digest splitting), so this only ever
/// runs as a narrower, dumber backstop for the one case the model can't
/// attempt at all.
///
/// Deliberately conservative about what counts as a usable result: amount
/// and date both have to be found with real confidence — a genuine rupee
/// figure actually present in the text and a genuine calendar date NSData
/// Detector recognized — or this returns nil rather than a half-filled
/// guess, so the caller falls through to the ordinary "couldn't parse"
/// state instead of showing a candidate with a fabricated amount or a
/// silently-defaulted-to-today date. Merchant and last-four digits are
/// filled in on a pure best-effort basis on top of that and are allowed to
/// come back nil — neither gates the result, since a transaction missing
/// just its merchant guess is still far more useful reviewed than not
/// shown at all.
enum DeterministicEmailParser {
    static func extract(emailBody: String, subject: String) -> ParsedTransaction? {
        guard let amount = firstAmount(in: emailBody) else { return nil }
        guard let dateString = firstDateString(in: emailBody) else { return nil }

        return ParsedTransaction(
            amount: amount,
            type: inferredType(in: emailBody),
            categoryName: nil,
            accountName: nil,
            note: nil,
            merchantName: merchantGuess(in: emailBody) ?? bankNameFallback(in: subject),
            lastFourDigits: lastFourDigits(in: emailBody),
            resolvedDateString: dateString,
            paymentMethodName: nil,
            isGenuineTransaction: true
        )
    }

    // MARK: - Amount

    /// Matches "Rs. 1,234.56", "Rs.30.00", "INR1,000.00", "INR 500" — same
    /// shapes EmailTransactionParser.currencyAmounts already recognizes for
    /// its own, separate purpose (counting how many amounts an email
    /// cites). Takes the *first* match in the body, not the largest or a
    /// sum: every real alert seen so far states the actual transaction
    /// amount before any secondary figure (a running/available balance, a
    /// credit limit) — see EmailTransactionParser's investigation history.
    private static let amountPattern = #"(?:rs\.?|inr|₹)\s?([\d,]+(?:\.\d{1,2})?)"#

    private static func firstAmount(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: amountPattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text) else { return nil }
        let numberString = text[numberRange].replacingOccurrences(of: ",", with: "")
        return Double(numberString)
    }

    // MARK: - Date

    /// NSDataDetector rather than a hand-written date regex — real alerts
    /// print the date in whatever format that issuer prefers ("Aug 28,
    /// 2026 at 11:26:50", "28-08-26", "27-08-2026"), and NSDataDetector's
    /// own locale-aware date recognition already handles far more of that
    /// variety than a fixed pattern list would, the same reasoning
    /// ParsedTransaction.parseFlexibleDate's multi-format fallback exists
    /// for on the model's own output.
    ///
    /// Inserts a space after any period immediately followed by a letter
    /// before handing the text to NSDataDetector — confirmed against a
    /// real RBL alert ("...on 27-08-2026.AVL limit- INR24,000.00.") that
    /// NSDataDetector silently fails to recognize the date at all when a
    /// trailing period runs straight into the next word with no space,
    /// even though the exact same date text on its own (or followed by a
    /// space) matches fine. Doesn't touch a decimal amount like
    /// "1,004.00" — that period is always followed by another digit, never
    /// a letter, so this never risks splitting a number apart.
    private static func firstDateString(in text: String) -> String? {
        let spaced = text.replacingOccurrences(of: #"\.([A-Za-z])"#, with: ". $1", options: .regularExpression)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(spaced.startIndex..., in: spaced)
        guard let match = detector.firstMatch(in: spaced, range: range), let date = match.date else { return nil }
        return isoDateFormatter.string(from: date)
    }

    /// Same yyyy-MM-dd/en_US_POSIX shape ParsedTransaction.parseFlexibleDate
    /// expects as its primary format, so a value from here round-trips
    /// through resolvedDate without needing any of that type's other
    /// fallback formats.
    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Last four digits

    /// Tried in order against the whole body — "XX2002" (ICICI), "ending
    /// 1320" (HDFC), "(7063)" (RBL, a bare parenthesized card reference)
    /// are the three shapes seen in real alerts from these issuers so far;
    /// none of them are bank-specific in the sense of only matching that
    /// one bank's wording, since any issuer could plausibly use any of the
    /// three.
    private static let lastFourPatterns = [
        #"xx\s?(\d{4})"#,
        #"ending\s+(\d{4})"#,
        #"\((\d{4})\)"#,
    ]

    private static func lastFourDigits(in text: String) -> String? {
        for pattern in lastFourPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let digitsRange = Range(match.range(at: 1), in: text) {
                return String(text[digitsRange])
            }
        }
        return nil
    }

    // MARK: - Merchant

    /// Text immediately following a connector word near the transaction
    /// detail — "at ROYAL PETRO PARK" (RBL), "Info: AMAZON PAY ECOM"
    /// (ICICI) — stopping at the next sentence boundary, "(", or a
    /// following " on " (which almost always introduces the date, e.g.
    /// "at ROYAL PETRO PARK on RBL Bank credit card"). Deliberately
    /// excludes "for"/"to" despite them reading like natural candidates —
    /// confirmed against a real ICICI alert ("...has been used **for** a
    /// transaction of INR 1,004.00...") that "for" matches the boilerplate
    /// phrase itself (capturing "a transaction of INR 1", stopping at the
    /// comma in "1,004.00") well before the actual merchant mention
    /// further down the email, since it's the first "for" in the text.
    /// "at"/"towards"/"info:" don't share that problem — they show up in
    /// these alerts only right before the genuine merchant/VPA reference —
    /// so the connector list stays narrower than "near the amount" might
    /// suggest, in favor of not matching first and matching wrong.
    private static let merchantConnectorPattern =
        #"(?:\bat\b|\btowards\b|\binfo:)\s+([A-Za-z][A-Za-z0-9 &.,'/\-]{1,40}?)(?=\s+on\s|[.,(]|$)"#

    /// A UPI VPA reference usually carries its own human-readable name in
    /// parentheses right after the handle — "VPA credsilver.autopay@axisb
    /// (CRED SILVER)" — which reads far better as a merchant guess than
    /// the raw VPA handle itself, so this is tried before the generic
    /// connector-word search below.
    private static let vpaFriendlyNamePattern = #"VPA\s+\S+\s*\(([^)]{2,40})\)"#

    private static func merchantGuess(in text: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: vpaFriendlyNamePattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let nameRange = Range(match.range(at: 1), in: text) {
            return String(text[nameRange]).trimmingCharacters(in: .whitespaces)
        }

        guard let regex = try? NSRegularExpression(pattern: merchantConnectorPattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let nameRange = Range(match.range(at: 1), in: text) else { return nil }
        let raw = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// Last resort when no merchant could be isolated at all: the subject
    /// line of a bank alert almost always names the issuer ("Transaction
    /// alert for your ICICI Bank Credit Card") — a "<Word> Bank" label
    /// beats leaving the row with nothing to show but the raw subject.
    private static func bankNameFallback(in subject: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Z][A-Za-z]+\s+Bank)"#),
              let match = regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
              let range = Range(match.range(at: 1), in: subject) else { return nil }
        return String(subject[range])
    }

    // MARK: - Type

    /// Same expense/income split EmailTransactionParser's own instructions
    /// ask the model for, applied deterministically here: a handful of
    /// credit-side keywords flip it to "income," everything else defaults
    /// to "expense" — the overwhelming majority of transaction alerts are
    /// debits, so an unrecognized wording is far more likely a spend than
    /// a credit.
    private static func inferredType(in text: String) -> String {
        let lowercased = text.lowercased()
        let incomeWords = ["credited", "credit of", "refunded", "refund of", "received"]
        return incomeWords.contains(where: lowercased.contains) ? "income" : "expense"
    }
}
