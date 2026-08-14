//
//  EmailTransactionCandidate.swift
//  Panam
//

import Foundation

/// A single fetched transaction-alert email, parsed (or not) into transaction
/// fields for review. Held only in memory for the duration of a review
/// session — deliberately not a SwiftData @Model, since nothing here is
/// worth persisting until the user actually imports it as a real Transaction.
struct EmailTransactionCandidate: Identifiable {
    var id: String { gmailMessageID }

    let gmailMessageID: String
    let rawSubject: String
    let rawSnippet: String
    let parsed: ParsedTransaction?
    let parseError: String?
    /// Set when EmailTransactionParser.matchRefund found an existing debit
    /// this candidate looks like a refund for — `parsed` has already been
    /// reclassified to .refund by that point. Carried along purely for
    /// display (the "Matched refund for…" review label) and so the
    /// eventual Transaction can link back to it via `refundedTransaction`.
    var matchedRefundTransaction: Transaction? = nil
}
