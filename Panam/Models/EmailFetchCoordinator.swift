//
//  EmailFetchCoordinator.swift
//  Panam
//

import Foundation
import PDFKit
import SwiftUI // for IndexSet's remove(atOffsets:), used by removeTransactionCandidates/removeStatementUnmatched

/// Which batch fetch is currently running (or last ran) — drives the
/// persistent indicator's label ("Fetching transactions…" vs "Fetching
/// statements…") and which result set (transactionCandidates vs the
/// statement fields) is the relevant one to show.
enum FetchKind {
    case transactions
    case statements
    case dematStatements
}

/// One row's state in Statement Mails' Fetched Emails list — locked/
/// unlocked is settled up front (see EmailFetchCoordinator.startStatementFetch);
/// processing/done/failed track what happens after, whether that's automatic
/// (already unlocked) or triggered by tapping a locked row in the sheet.
enum FetchedEmailStatus: Equatable {
    case locked
    case unlocked
    case processing
    case done
    case failed(String)
}

/// One Gmail-fetched statement email paired with its downloaded PDF (nil
/// only when the attachment itself couldn't even be read as a PDF) and its
/// current FetchedEmailStatus.
struct FetchedStatementEmail: Identifiable {
    var id: String { summary.id }
    let summary: GmailMessageSummary
    let document: PDFDocument?
    var status: FetchedEmailStatus
}

/// Owns every piece of state a Transaction Mails / Statement Mails batch
/// fetch needs, injected app-wide via `.environment(...)` from PanamApp
/// rather than scoped to whichever sheet happens to be presented — so
/// backing out of Email Management, going to Dashboard, coming back, never
/// interrupts or silently drops a fetch already in flight. It's also the
/// single owner of the *results* (candidates, matched/unmatched lists), so
/// re-opening a sheet later shows whatever's completed so far, mid-fetch or
/// done, rather than an empty list because the view that owned it went away.
///
/// TransactionMailsSheet/StatementMailsSheet only read this state to render
/// and call the startX()/cancelFetch() methods below — the actual Gmail
/// search → parse/extract → reconcile work happens in the `Task` this class
/// owns (started from startX(), stored in `task`), not in a View's
/// lifetime-scoped `Task { }`.
@MainActor
@Observable
final class EmailFetchCoordinator {
    private(set) var isFetching = false
    private(set) var fetchType: FetchKind?
    private(set) var processedCount = 0
    private(set) var totalCount = 0
    private(set) var fetchStartedAt: Date?
    private(set) var fetchErrorMessage: String?

    // MARK: Transaction Mails results

    private(set) var transactionCandidates: [EmailTransactionCandidate] = []

    // MARK: Statement Mails results

    private(set) var fetchedEmails: [FetchedStatementEmail] = []
    private(set) var statementMatchedCount = 0
    private(set) var statementTotalCount = 0
    private(set) var statementUnmatched: [StatementReconciliationCandidate] = []

    // MARK: Demat Statements results

    /// Same FetchedStatementEmail/FetchedEmailStatus shape Statement Mails
    /// uses — a summary + downloaded PDF + lock/processing status is just
    /// as accurate a description for a demat holdings statement email as a
    /// bank one, so this reuses the type directly rather than declaring a
    /// near-identical one.
    private(set) var fetchedDematEmails: [FetchedStatementEmail] = []
    private(set) var dematTotalHoldingsCount = 0
    /// Holdings whose extracted instrument name exactly matched an
    /// Investment's already-remembered upstoxHoldingName — applied straight
    /// through with no review, which is the whole point of remembering that
    /// mapping in the first place. See processDematRow/confirmDematMatch.
    private(set) var dematAutoUpdatedCount = 0
    private(set) var dematReviewCandidates: [DematHoldingReviewCandidate] = []

    /// The currently-running fetch, kept only so cancelFetch() can call
    /// task?.cancel() — never awaited directly, nothing needs to block on
    /// it finishing.
    private var task: Task<Void, Never>?

    // MARK: - Cancellation

    /// Cancels whatever's running — cooperative, not instant: the Task's
    /// loop checks Task.isCancelled before processing each email and exits
    /// cleanly on the next check, not mid-item. Resets the in-flight flags
    /// immediately, though, so the UI (the persistent indicator, the
    /// sheet's own Fetch Emails button) reflects "stopped" right away
    /// regardless of what the Task itself is still mid-await on. Once the
    /// Task does notice the cancellation, it returns without touching
    /// isFetching/fetchType again — see the `guard !Task.isCancelled`
    /// checks below — so it can never race this reset. Deliberately leaves
    /// processedCount/totalCount and whatever results already accumulated
    /// alone: a cancelled fetch still shows however far it got, same as
    /// reopening a sheet on one that ran to completion.
    func cancelFetch() {
        task?.cancel()
        task = nil
        isFetching = false
        fetchType = nil
    }

    // MARK: - Transaction Mails

    func startTransactionFetch(
        senderTerms: [String], categories: [Category], accounts: [Account], transactions: [Transaction]
    ) {
        guard !isFetching else { return }
        isFetching = true
        fetchType = .transactions
        fetchErrorMessage = nil
        processedCount = 0
        totalCount = 0
        fetchStartedAt = nil
        transactionCandidates = []

        // A no-op after the first time the user's answered the system
        // prompt either way — see requestAuthorizationIfNeeded. Fired here
        // (rather than only from Settings) so a fetch-complete notification
        // has permission to actually show by the time this same fetch
        // finishes, without requiring a trip to Settings first.
        Task { await NotificationManager.shared.requestAuthorizationIfNeeded() }

        task = Task { [weak self] in
            await self?.runTransactionFetch(
                senderTerms: senderTerms, categories: categories, accounts: accounts, transactions: transactions
            )
        }
    }

    private func runTransactionFetch(
        senderTerms: [String], categories: [Category], accounts: [Account], transactions: [Transaction]
    ) async {
        do {
            let messages = try await GmailFetcher.fetchCandidateMessages(senderTerms: senderTerms)
            guard !Task.isCancelled else { return }
            totalCount = messages.count
            fetchStartedAt = .now

            var results: [EmailTransactionCandidate] = []
            for message in messages {
                guard !Task.isCancelled else { return }
                // Cheap keyword/structure screen before the email ever
                // reaches the model — promotional/T&Cs/fee-notice mail
                // never gets this far, so it never costs a model call and
                // never has a chance to show up as a bogus candidate. See
                // looksLikeTransactionAlert's doc comment.
                guard EmailTransactionParser.looksLikeTransactionAlert(
                    emailBody: message.bodyText, subject: message.subject
                ) else {
                    processedCount += 1
                    continue
                }
                do {
                    // Zero or more entries — EmailTransactionParser.parse
                    // already applied its own isGenuineTransaction gate per
                    // entry (see that function's doc comment), the same
                    // "false negative silently dropped rather than shown"
                    // intent the single-transaction version always had, now
                    // independently per entry rather than for the whole
                    // email. A bundled digest maps to as many candidates
                    // here as it has genuine entries — each one reviewable/
                    // editable/importable/deletable on its own (see
                    // EmailTransactionCandidate's doc comment).
                    let parsedEntries = try await EmailTransactionParser.parse(
                        emailBody: message.bodyText,
                        subject: message.subject,
                        categories: categories,
                        accounts: accounts
                    )
                    for parsedRaw in parsedEntries {
                        // Deterministic post-processing, not part of the
                        // model's own output — see matchRefund's doc
                        // comment. Run per entry: each bundled transaction
                        // in a digest can independently turn out to be a
                        // refund for its own separate earlier debit.
                        let (parsed, matchedRefund) = EmailTransactionParser.matchRefund(
                            for: parsedRaw, against: transactions
                        )
                        results.append(EmailTransactionCandidate(
                            gmailMessageID: message.id,
                            rawSubject: message.subject,
                            rawSnippet: message.snippet,
                            parsed: parsed,
                            parseError: nil,
                            matchedRefundTransaction: matchedRefund
                        ))
                    }
                } catch {
                    results.append(EmailTransactionCandidate(
                        gmailMessageID: message.id,
                        rawSubject: message.subject,
                        rawSnippet: message.snippet,
                        parsed: nil,
                        parseError: error.localizedDescription
                    ))
                }
                processedCount += 1
                // Updated every iteration (not just at the end) so a sheet
                // reopened mid-fetch — or one left open the whole time —
                // sees candidates land one by one, same as the fetch
                // actually happening.
                transactionCandidates = results
            }
            guard !Task.isCancelled else { return }
            isFetching = false
            fetchType = nil
            // Fires whether or not anyone's watching this screen right
            // now — the whole point of routing statement downloads
            // through a background URLSession is that a fetch can finish
            // while Transaction Mails isn't even on screen, so this is
            // often the only signal the fetch ever completed. Counts
            // successfully parsed candidates only; a parse failure isn't
            // a "transaction found."
            NotificationManager.shared.notifyFetchComplete(
                kind: "Transaction", newCount: results.filter { $0.parsed != nil }.count
            )
        } catch {
            guard !Task.isCancelled else { return }
            fetchErrorMessage = error.localizedDescription
            isFetching = false
            fetchType = nil
        }
    }

    /// The single import completion path — TransactionMailsSheet calls
    /// this instead of separately calling GmailFetcher.markImported and
    /// mutating the candidates array itself, since both now have to happen
    /// together correctly: removes exactly this one candidate, never its
    /// siblings bundled from the same digest email (see
    /// EmailTransactionCandidate's doc comment), and only marks the source
    /// Gmail message imported once every candidate that came from it is
    /// gone from the review list.
    ///
    /// Marking the whole message imported the moment just one of its
    /// bundled transactions is would make Gmail stop resurfacing it
    /// entirely on a future fetch — and startTransactionFetch wipes
    /// transactionCandidates on every new fetch, so any still-pending
    /// sibling not yet imported would be lost for good, not just
    /// re-shown. Waiting for every sibling to clear first (imported or
    /// deleted) keeps the source email eligible for a future fetch for as
    /// long as any of its bundled transactions are still un-reviewed.
    func markCandidateImported(_ candidate: EmailTransactionCandidate) {
        transactionCandidates.removeAll { $0.id == candidate.id }
        let hasPendingSibling = transactionCandidates.contains { $0.gmailMessageID == candidate.gmailMessageID }
        if !hasPendingSibling {
            GmailFetcher.markImported(candidate.gmailMessageID)
        }
    }

    func removeTransactionCandidates(at offsets: IndexSet) {
        transactionCandidates.remove(atOffsets: offsets)
    }

    // MARK: - Statement Mails (Gmail batch fetch)

    func startStatementFetch(senderTerms: [String], accounts: [Account], transactions: [Transaction]) {
        guard !isFetching else { return }
        isFetching = true
        fetchType = .statements
        fetchErrorMessage = nil
        statementMatchedCount = 0
        statementTotalCount = 0
        statementUnmatched = []
        fetchedEmails = []
        processedCount = 0
        totalCount = 0
        fetchStartedAt = nil

        Task { await NotificationManager.shared.requestAuthorizationIfNeeded() }

        task = Task { [weak self] in
            await self?.runStatementFetch(senderTerms: senderTerms, accounts: accounts, transactions: transactions)
        }
    }

    /// Searches Gmail for every matching statement email, then — instead of
    /// looping straight into extraction and interrupting sequentially for
    /// each locked one with no context — first downloads every attachment
    /// and settles each one's lock status (trying a saved Keychain
    /// password silently) into fetchedEmails, so the whole batch shows up
    /// as a selectable list with visible status before anything auto-
    /// processes or prompts. Once that's populated, whatever's already
    /// unlocked processes on its own, right here; anything still locked
    /// just sits there — in fetchedEmails, so it's still there whenever the
    /// sheet is reopened — until the user taps it (StatementMailsSheet's
    /// rowTapped(_:), which unlocks then calls processRow(at:...) below).
    /// isFetching stays true across both phases, not just the download one
    /// — the persistent indicator and Cancel button should stay live for as
    /// long as this is actually still doing work.
    private func runStatementFetch(senderTerms: [String], accounts: [Account], transactions: [Transaction]) async {
        do {
            let summaries = try await GmailFetcher.searchStatementEmails(senderTerms: senderTerms)
            guard !Task.isCancelled else { return }
            guard !summaries.isEmpty else {
                fetchErrorMessage = "No statement emails found for these senders in the last 6 months."
                isFetching = false
                fetchType = nil
                return
            }
            totalCount = summaries.count
            fetchStartedAt = .now

            for summary in summaries {
                guard !Task.isCancelled else { return }
                guard let data = try? await GmailFetcher.downloadAttachment(
                    messageID: summary.id, attachmentID: summary.attachmentID
                ), let document = PDFDocument(data: data) else {
                    fetchedEmails.append(FetchedStatementEmail(
                        summary: summary, document: nil,
                        status: .failed("Couldn't read this attachment as a PDF.")
                    ))
                    processedCount += 1
                    continue
                }
                if document.isLocked {
                    _ = StatementReconciler.unlockWithSavedPassword(document, accounts: accounts)
                }
                fetchedEmails.append(FetchedStatementEmail(
                    summary: summary, document: document,
                    status: document.isLocked ? .locked : .unlocked
                ))
                processedCount += 1
            }

            for index in fetchedEmails.indices where fetchedEmails[index].status == .unlocked {
                guard !Task.isCancelled else { return }
                await processRow(at: index, accounts: accounts, transactions: transactions)
            }

            guard !Task.isCancelled else { return }
            isFetching = false
            fetchType = nil
            // Same rationale as runTransactionFetch's notification — a
            // statement's attachment download is the one request in this
            // whole pipeline that can genuinely keep running after the
            // app backgrounds (see BackgroundDownloadManager), so this is
            // often the only signal the user gets that it's done.
            // statementUnmatched was reset to [] at the top of
            // startStatementFetch, so its count here is entirely this run's.
            NotificationManager.shared.notifyFetchComplete(kind: "Statement", newCount: statementUnmatched.count)
        } catch {
            guard !Task.isCancelled else { return }
            isFetching = false
            fetchType = nil
            fetchErrorMessage = error.localizedDescription
        }
    }

    /// Runs one fetched email's unlocked PDF — either one that was already
    /// unlocked when the batch downloaded it, or a previously-.locked one
    /// StatementMailsSheet just unlocked via its password prompt (see
    /// markRowUnlocked(at:)) — through extract → reconcile, adding its
    /// results into the shared matched/total/unmatched state rather than
    /// overwriting it, so every row's contribution accumulates. Public
    /// since StatementMailsSheet calls this directly for the
    /// password-prompt-driven path, outside runStatementFetch's own loop.
    func processRow(at index: Int, accounts: [Account], transactions: [Transaction]) async {
        guard fetchedEmails.indices.contains(index), let document = fetchedEmails[index].document else { return }
        fetchedEmails[index].status = .processing
        do {
            let text = try StatementReconciler.extractText(from: document)
            let entries = try await StatementReconciler.extractLineItems(from: text)
            let result = StatementReconciler.reconcile(
                entries: entries, against: transactions, accounts: accounts
            )
            statementMatchedCount += result.matchedCount
            statementTotalCount += entries.count
            statementUnmatched.append(contentsOf: result.unmatched)
            fetchedEmails[index].status = .done
        } catch {
            fetchedEmails[index].status = .failed(error.localizedDescription)
        }
    }

    /// StatementMailsSheet's rowTapped flow calls this right after a
    /// locked row's password prompt succeeds, before handing off to
    /// processRow(at:accounts:transactions:) to actually extract/reconcile it.
    func markRowUnlocked(at index: Int) {
        guard fetchedEmails.indices.contains(index) else { return }
        fetchedEmails[index].status = .unlocked
    }

    // MARK: - Statement Mails (manual single-PDF pick)

    /// Runs one manually-picked PDF — or one unlocked via the password
    /// prompt outside a Gmail batch — through the same extract → reconcile
    /// pipeline, merging into the very same statementMatchedCount/
    /// statementTotalCount/statementUnmatched state: one shared results
    /// section serves both entry points. Deliberately not run through
    /// `task`/cancelFetch's cooperative cancellation machinery — a single
    /// document is quick, and isFetching here only exists to disable the
    /// picker button while it runs and to surface it on the persistent
    /// indicator like any other in-flight fetch.
    func processManualStatement(_ document: PDFDocument, accounts: [Account], transactions: [Transaction]) {
        guard !isFetching else { return }
        isFetching = true
        fetchType = .statements
        fetchErrorMessage = nil

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try StatementReconciler.extractText(from: document)
                let entries = try await StatementReconciler.extractLineItems(from: text)
                guard !Task.isCancelled else { return }
                let result = StatementReconciler.reconcile(
                    entries: entries, against: transactions, accounts: accounts
                )
                self.statementMatchedCount += result.matchedCount
                self.statementTotalCount += entries.count
                self.statementUnmatched.append(contentsOf: result.unmatched)
                self.isFetching = false
                self.fetchType = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.isFetching = false
                self.fetchType = nil
                self.fetchErrorMessage = error.localizedDescription
            }
        }
    }

    /// StatementMailsSheet's manual-pick path calls this for a failure that
    /// happens before there's even a PDFDocument to hand to
    /// processManualStatement (an unreadable file, or data that isn't a
    /// valid PDF at all) — surfaced through the same fetchErrorMessage the
    /// Gmail batch fetch uses, since both show in the same spot in the sheet.
    func reportManualStatementError(_ message: String) {
        fetchErrorMessage = message
    }

    func removeStatementUnmatched(id: UUID) {
        statementUnmatched.removeAll { $0.id == id }
    }

    func removeStatementUnmatched(at offsets: IndexSet) {
        statementUnmatched.remove(atOffsets: offsets)
    }

    // MARK: - Demat Statements (Gmail batch fetch)

    /// Mirrors startStatementFetch/runStatementFetch exactly — same
    /// download-everything-then-settle-lock-status-then-process shape (see
    /// that method's doc comment) — swapping StatementReconciler's
    /// extract→reconcile pipeline for DematHoldingExtractor's
    /// extract→match one. No manual-PDF-pick counterpart exists here (out
    /// of scope for the first pass): every locked Demat PDF's password is
    /// attributed to the Gmail row it came from, never to a bare document.
    func startDematFetch(senderTerms: [String], investments: [Investment]) {
        guard !isFetching else { return }
        isFetching = true
        fetchType = .dematStatements
        fetchErrorMessage = nil
        fetchedDematEmails = []
        dematTotalHoldingsCount = 0
        dematAutoUpdatedCount = 0
        dematReviewCandidates = []
        processedCount = 0
        totalCount = 0
        fetchStartedAt = nil

        Task { await NotificationManager.shared.requestAuthorizationIfNeeded() }

        task = Task { [weak self] in
            await self?.runDematFetch(senderTerms: senderTerms, investments: investments)
        }
    }

    private func runDematFetch(senderTerms: [String], investments: [Investment]) async {
        do {
            let summaries = try await GmailFetcher.searchStatementEmails(senderTerms: senderTerms)
            guard !Task.isCancelled else { return }
            guard !summaries.isEmpty else {
                fetchErrorMessage = "No demat statement emails found for these senders in the last 6 months."
                isFetching = false
                fetchType = nil
                return
            }
            totalCount = summaries.count
            fetchStartedAt = .now

            for summary in summaries {
                guard !Task.isCancelled else { return }
                guard let data = try? await GmailFetcher.downloadAttachment(
                    messageID: summary.id, attachmentID: summary.attachmentID
                ), let document = PDFDocument(data: data) else {
                    fetchedDematEmails.append(FetchedStatementEmail(
                        summary: summary, document: nil,
                        status: .failed("Couldn't read this attachment as a PDF.")
                    ))
                    processedCount += 1
                    continue
                }
                // Keyed by sender rather than an Account's last-4 — see
                // KeychainStore's Demat statement PDF passwords section.
                if document.isLocked, let savedPassword = KeychainStore.dematPassword(forSender: summary.from) {
                    _ = document.unlock(withPassword: savedPassword)
                }
                fetchedDematEmails.append(FetchedStatementEmail(
                    summary: summary, document: document,
                    status: document.isLocked ? .locked : .unlocked
                ))
                processedCount += 1
            }

            for index in fetchedDematEmails.indices where fetchedDematEmails[index].status == .unlocked {
                guard !Task.isCancelled else { return }
                await processDematRow(at: index, investments: investments)
            }

            guard !Task.isCancelled else { return }
            isFetching = false
            fetchType = nil
            NotificationManager.shared.notifyFetchComplete(
                kind: "Demat Holdings", newCount: dematReviewCandidates.count
            )
        } catch {
            guard !Task.isCancelled else { return }
            isFetching = false
            fetchType = nil
            fetchErrorMessage = error.localizedDescription
        }
    }

    /// Runs one fetched email's unlocked PDF through extract → match,
    /// mirroring processRow(at:accounts:transactions:) above. A holding
    /// whose exact instrument name is already remembered on some Investment
    /// (upstoxHoldingName) updates that Investment directly, right here, no
    /// review needed — everything else becomes a DematHoldingReviewCandidate
    /// instead. Public for the same reason processRow is: DematStatementsSheet
    /// calls this directly for the password-prompt-driven path, outside
    /// runDematFetch's own loop.
    func processDematRow(at index: Int, investments: [Investment]) async {
        guard fetchedDematEmails.indices.contains(index), let document = fetchedDematEmails[index].document else { return }
        fetchedDematEmails[index].status = .processing
        do {
            let text = try StatementReconciler.extractText(from: document)
            let holdings = try await DematHoldingExtractor.extractHoldings(from: text)
            dematTotalHoldingsCount += holdings.count

            for holding in holdings {
                let current = DematHoldingExtractor.parseAmount(holding.currentValueString)

                if let remembered = investments.first(where: { $0.upstoxHoldingName == holding.instrumentName }) {
                    remembered.currentValue = current
                    remembered.lastValuationDate = .now
                    dematAutoUpdatedCount += 1
                } else {
                    let suggested = DematHoldingExtractor.matchInvestment(for: holding, in: investments)
                    dematReviewCandidates.append(DematHoldingReviewCandidate(
                        holding: holding, currentValue: current,
                        suggestedInvestment: suggested
                    ))
                }
            }
            fetchedDematEmails[index].status = .done
        } catch {
            fetchedDematEmails[index].status = .failed(error.localizedDescription)
        }
    }

    func markDematRowUnlocked(at index: Int) {
        guard fetchedDematEmails.indices.contains(index) else { return }
        fetchedDematEmails[index].status = .unlocked
    }

    /// DematStatementsSheet's "Change Match" picker calls this to update a
    /// still-pending candidate's suggestion in place — index-based mutation
    /// of the stored array (same pattern fetchedEmails[index].status = ...
    /// uses above) so the reactive row actually re-renders.
    func reassignDematCandidate(_ candidateID: UUID, to investment: Investment?) {
        guard let index = dematReviewCandidates.firstIndex(where: { $0.id == candidateID }) else { return }
        dematReviewCandidates[index].suggestedInvestment = investment
    }

    /// The review row's editable current-value field calls this on every
    /// keystroke — same index-based-mutation approach as
    /// reassignDematCandidate, so the live returns-percent recalculation
    /// (DematHoldingRow) always reflects what's about to be confirmed, not
    /// what the statement originally said.
    func updateDematCandidateCurrentValue(_ candidateID: UUID, to newValue: Double?) {
        guard let index = dematReviewCandidates.firstIndex(where: { $0.id == candidateID }) else { return }
        dematReviewCandidates[index].currentValue = newValue
    }

    /// The confirmed-match action: writes currentValue/lastValuationDate and
    /// remembers upstoxHoldingName so every later statement's identical
    /// instrument name auto-updates from here on (see processDematRow's
    /// remembered-match branch) — investedValue/totalContributed are never
    /// touched, by design (see Investment.currentValue's doc comment).
    func confirmDematMatch(_ candidate: DematHoldingReviewCandidate, investment: Investment) {
        investment.upstoxHoldingName = candidate.holding.instrumentName
        investment.currentValue = candidate.currentValue
        investment.lastValuationDate = .now
        dematReviewCandidates.removeAll { $0.id == candidate.id }
    }

    /// Dismisses a candidate without applying it — "not a holding I track in
    /// Panam," same non-destructive intent as deleteUnmatched/
    /// deleteCandidates elsewhere: nothing's been saved yet, so free to
    /// reappear on a later fetch.
    func skipDematCandidate(_ candidate: DematHoldingReviewCandidate) {
        dematReviewCandidates.removeAll { $0.id == candidate.id }
    }

    func removeDematCandidates(at offsets: IndexSet) {
        dematReviewCandidates.remove(atOffsets: offsets)
    }
}
