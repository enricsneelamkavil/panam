//
//  StatementAutoFetchProcessor.swift
//  Panam
//

import Foundation
import SwiftData
import PDFKit
import GoogleSignIn

/// The outcome of one automatic per-card statement check — kept just long
/// enough to surface once in EmailManagementView, then cleared. Stored in
/// UserDefaults, not SwiftData: this is throwaway UI state, not financial
/// data, same tier as GmailFetcher's importedMessageIDs tracking.
struct StatementAutoFetchNotice: Codable, Identifiable {
    var id: String { "\(accountBackupID.uuidString)-\(checkedAt.timeIntervalSince1970)" }
    let accountBackupID: UUID
    let accountName: String
    let checkedAt: Date
    let matchedCount: Int
    let totalCount: Int
    let unmatchedCount: Int
}

/// UserDefaults-backed storage for StatementAutoFetchProcessor: the pending
/// notices themselves, plus a per-account "last successfully checked" date
/// used to avoid re-running the same card's search more than once per
/// statement cycle. Keyed by Account.backupID (not persistentModelID,
/// which isn't a stable, storable value) — the same stable identifier
/// DriveBackupManager already relies on to survive a backup/restore round trip.
enum StatementAutoFetchStore {
    private static let noticesKey = "statementAutoFetchNotices"
    private static let lastCheckedKeyPrefix = "statementAutoFetchLastChecked."

    static var notices: [StatementAutoFetchNotice] {
        get {
            guard let data = UserDefaults.standard.data(forKey: noticesKey) else { return [] }
            return (try? JSONDecoder().decode([StatementAutoFetchNotice].self, from: data)) ?? []
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: noticesKey)
        }
    }

    static func addNotice(_ notice: StatementAutoFetchNotice) {
        notices.append(notice)
    }

    /// Called once EmailManagementView has shown the pending notices —
    /// marks them read so they don't reappear on the next visit.
    static func clearNotices() {
        notices = []
    }

    static func lastCheckedDate(forAccountBackupID backupID: UUID) -> Date? {
        UserDefaults.standard.object(forKey: lastCheckedKeyPrefix + backupID.uuidString) as? Date
    }

    static func recordChecked(forAccountBackupID backupID: UUID, date: Date) {
        UserDefaults.standard.set(date, forKey: lastCheckedKeyPrefix + backupID.uuidString)
    }
}

/// Runs once per app launch (see PanamApp, after Gmail session restore): for
/// every credit card with a statementFetchDay set whose current cycle's
/// fetch day has arrived and hasn't already been checked this cycle,
/// searches Gmail for a statement, silently unlocks a password-protected
/// one using a Keychain-saved password (see KeychainStore.statementPassword
/// / EmailManagementView's Statement Mails "Save password for this card"),
/// and reconciles it — recording the outcome as an in-app notice via
/// StatementAutoFetchStore.
///
/// Deliberately never auto-imports a transaction from what it finds — that
/// still goes through the normal Statement Mails review
/// flow, same as every other import path in this app. This only saves the
/// trip to go trigger the search by hand.
enum StatementAutoFetchProcessor {
    static func runIfNeeded(context: ModelContext) async {
        // Cheap bail-out before touching SwiftData or the network at all —
        // GmailFetcher would just throw notSignedIn moments later anyway,
        // but this avoids the fetch descriptors for the common guest-mode case.
        guard GIDSignIn.sharedInstance.currentUser != nil else { return }

        guard let allAccounts = try? context.fetch(FetchDescriptor<Account>()) else { return }
        let today = Date.now
        let dueCards = allAccounts.filter { card in
            card.type == .creditCard
                && card.statementFetchDay != nil
                && isDue(day: card.statementFetchDay!, today: today, accountBackupID: card.backupID)
        }
        guard !dueCards.isEmpty else { return }

        let senderTerms = AppSettings.parseSenderTerms(
            UserDefaults.standard.string(forKey: AppSettings.statementSenderTermsKey)
                ?? AppSettings.statementSenderTermsDefault
        )
        guard !senderTerms.isEmpty else { return }

        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []

        guard let summaries = try? await GmailFetcher.searchStatementEmails(senderTerms: senderTerms) else {
            // A transient failure (token refresh, network, etc.) — leave
            // "last checked" untouched so this retries on the next launch
            // rather than silently going quiet for the rest of the cycle.
            return
        }

        // One shared search covers every due card at once (they all draw
        // from the same statementSenderTerms list) — mark all of them
        // checked now that the search itself succeeded, whether or not a
        // given card's statement happened to be in this batch.
        for card in dueCards {
            StatementAutoFetchStore.recordChecked(forAccountBackupID: card.backupID, date: today)
        }

        var results: [PersistentIdentifier: (matched: Int, total: Int, unmatched: Int)] = [:]

        for summary in summaries {
            guard let data = try? await GmailFetcher.downloadAttachment(
                messageID: summary.id, attachmentID: summary.attachmentID
            ), let document = PDFDocument(data: data) else { continue }

            let owningCard: Account?
            if document.isLocked {
                // Trying every due card's saved password both unlocks the
                // PDF and identifies whose statement it is in one step —
                // there's no readable text to run detectAccount on until
                // it's unlocked.
                owningCard = StatementReconciler.unlockWithSavedPassword(document, accounts: dueCards)
                guard owningCard != nil else { continue }
            } else {
                owningCard = nil
            }

            guard let text = try? StatementReconciler.extractText(from: document) else { continue }

            let resolvedCard: Account?
            if let owningCard {
                resolvedCard = owningCard
            } else if let detected = StatementReconciler.detectAccount(in: text, accounts: allAccounts) {
                resolvedCard = dueCards.first { $0.persistentModelID == detected.persistentModelID }
            } else {
                resolvedCard = nil
            }
            guard let resolvedCard else { continue }

            guard let entries = try? await StatementReconciler.extractLineItems(from: text) else { continue }
            let result = StatementReconciler.reconcile(entries: entries, against: transactions, accounts: allAccounts)

            var entry = results[resolvedCard.persistentModelID] ?? (matched: 0, total: 0, unmatched: 0)
            entry.matched += result.matchedCount
            entry.total += entries.count
            entry.unmatched += result.unmatched.count
            results[resolvedCard.persistentModelID] = entry
        }

        for card in dueCards {
            guard let entry = results[card.persistentModelID] else { continue }
            StatementAutoFetchStore.addNotice(StatementAutoFetchNotice(
                accountBackupID: card.backupID,
                accountName: card.name,
                checkedAt: today,
                matchedCount: entry.matched,
                totalCount: entry.total,
                unmatchedCount: entry.unmatched
            ))
        }
    }

    /// Due once this cycle's fetch-day date has arrived — today's
    /// day-of-month equals `day`, or has already passed it this month —
    /// and nothing has been successfully checked since that date.
    private static func isDue(day: Int, today: Date, accountBackupID: UUID) -> Bool {
        guard let cycleFetchDate = mostRecentOccurrence(ofDay: day, onOrBefore: today) else { return false }
        guard let lastChecked = StatementAutoFetchStore.lastCheckedDate(forAccountBackupID: accountBackupID) else {
            return true
        }
        return lastChecked < cycleFetchDate
    }

    /// Most recent date this or an earlier month landed on `day` — mirrors
    /// CreditCardDetailView's day-of-month helpers ("today counts if it matches").
    private static func mostRecentOccurrence(ofDay day: Int, onOrBefore date: Date) -> Date? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        if calendar.component(.day, from: dayStart) == day {
            return dayStart
        }
        return calendar.nextDate(
            after: dayStart,
            matching: DateComponents(day: day),
            matchingPolicy: .nextTime,
            direction: .backward
        )
    }
}
