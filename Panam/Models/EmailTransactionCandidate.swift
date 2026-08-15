//
//  EmailTransactionCandidate.swift
//  Panam
//

import Foundation

/// A single reviewable transaction candidate, parsed (or not) into
/// transaction fields for review. Held only in memory for the duration of a
/// review session — deliberately not a SwiftData @Model, since nothing here
/// is worth persisting until the user actually imports it as a real
/// Transaction.
///
/// No longer one-to-one with a fetched email: EmailTransactionParser.parse
/// can return several entries for one bundled digest email (see its own doc
/// comment), so `id` is its own UUID rather than gmailMessageID — several
/// candidates legitimately share the same gmailMessageID now, and each has
/// to be independently reviewable/editable/importable/deletable without
/// touching its siblings. gmailMessageID stays around for exactly the
/// things that are still whole-email concerns: which Gmail message this
/// came from, and — see EmailFetchCoordinator.markCandidateImported —
/// only marking that message as imported (so it stops resurfacing on a
/// future fetch) once every candidate that came from it is gone from the
/// review list, not the moment just one of its bundled transactions is.
struct EmailTransactionCandidate: Identifiable {
    let id = UUID()

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
