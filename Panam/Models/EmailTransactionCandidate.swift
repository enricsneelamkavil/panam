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
}
