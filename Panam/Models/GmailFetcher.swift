//
//  GmailFetcher.swift
//  Panam
//

import Foundation
import GoogleSignIn

/// A single fetched Gmail message with its decoded plain-text body — the raw
/// material EmailTransactionParser turns into a ParsedTransaction.
struct GmailMessage {
    let id: String
    let subject: String
    let snippet: String
    let bodyText: String
}

/// A statement email found by searchStatementEmails — just enough to list
/// and identify it (subject/from/date) plus the PDF attachment's
/// messages.attachments identifier, which downloadAttachment(messageID:attachmentID:)
/// needs to actually pull the file down. Deliberately doesn't fetch the
/// attachment bytes up front — that only happens once the user taps a
/// specific email to import.
struct GmailMessageSummary: Identifiable {
    let id: String
    let subject: String
    let from: String
    let dateString: String
    let attachmentID: String
    let attachmentFilename: String
}

enum GmailFetchError: LocalizedError {
    case notSignedIn
    case tokenUnavailable
    case http(Int, String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Connect Gmail first."
        case .tokenUnavailable:
            return "Couldn't refresh the Google access token. Try disconnecting and reconnecting Gmail."
        case .http(let code, let message):
            return "Gmail API error \(code): \(message)"
        case .decoding:
            return "Couldn't read the response from Gmail."
        }
    }
}

/// Fetches candidate transaction emails from Gmail via the REST API, using
/// the OAuth access token from the signed-in Google account (gmail.readonly
/// scope, granted during GmailAuthManager.signIn()). No writes to Gmail ever.
enum GmailFetcher {
    private static let apiBase = "https://gmail.googleapis.com/gmail/v1/users/me"

    // MARK: - Imported-message tracking

    /// Message IDs already turned into a Transaction — kept so re-fetching
    /// doesn't re-surface the same email for review.
    private static let importedIDsKey = "gmailImportedMessageIDs"

    static var importedMessageIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: importedIDsKey) ?? [])
    }

    static func markImported(_ id: String) {
        var current = importedMessageIDs
        current.insert(id)
        UserDefaults.standard.set(Array(current), forKey: importedIDsKey)
    }

    // MARK: - Fetch

    /// Builds a Gmail search query from user-configured sender terms and a
    /// lookback window, lists matching messages, skips ones already imported,
    /// and fetches+decodes the body of every remaining one.
    static func fetchCandidateMessages(senderTerms: [String], lookbackDays: Int = 30) async throws -> [GmailMessage] {
        guard !senderTerms.isEmpty else { return [] }

        let accessToken = try await currentAccessToken()
        let fromClause = senderTerms.joined(separator: " OR ")
        let query = "from:(\(fromClause)) newer_than:\(lookbackDays)d"

        let messageIDs = try await listMessageIDs(query: query, accessToken: accessToken)
        let alreadyImported = importedMessageIDs
        let newIDs = messageIDs.filter { !alreadyImported.contains($0) }

        var messages: [GmailMessage] = []
        for id in newIDs {
            if let message = try await fetchMessage(id: id, accessToken: accessToken) {
                messages.append(message)
            }
        }
        return messages
    }

    /// Same messages.list pattern as fetchCandidateMessages, but against a
    /// separate, statement-specific sender/keyword list (statement emails
    /// come from different addresses and subject patterns than
    /// per-transaction alerts — "e-Statement," "Monthly Statement," etc.)
    /// and narrowed to messages that actually carry a PDF attachment.
    /// Doesn't consult/mark importedMessageIDs — that tracking is
    /// per-transaction-candidate, not meaningful for a whole statement file.
    static func searchStatementEmails(senderTerms: [String], lookbackDays: Int = 180) async throws -> [GmailMessageSummary] {
        guard !senderTerms.isEmpty else { return [] }

        let accessToken = try await currentAccessToken()
        let fromClause = senderTerms.joined(separator: " OR ")
        let query = "from:(\(fromClause)) has:attachment filename:pdf newer_than:\(lookbackDays)d"

        let messageIDs = try await listMessageIDs(query: query, accessToken: accessToken)

        var summaries: [GmailMessageSummary] = []
        for id in messageIDs {
            if let summary = try await fetchStatementSummary(id: id, accessToken: accessToken) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    /// Downloads one PDF attachment's raw bytes via messages.attachments.get.
    /// Gmail returns the content base64url-encoded, same alphabet as message
    /// bodies but decoded here straight to Data (an attachment is binary,
    /// not necessarily valid UTF-8 text like a message body is).
    ///
    /// Routed through BackgroundDownloadManager rather than the plain
    /// get(_:accessToken:) every other call in this file uses — a
    /// statement attachment is the one Gmail request worth surviving the
    /// app being backgrounded mid-download; see that type's doc comment.
    static func downloadAttachment(messageID: String, attachmentID: String) async throws -> Data {
        let accessToken = try await currentAccessToken()
        let url = URL(string: "\(apiBase)/messages/\(messageID)/attachments/\(attachmentID)")!
        let responseData = try await BackgroundDownloadManager.shared.download(url, accessToken: accessToken)
        let decoded = try JSONDecoder().decode(AttachmentResponse.self, from: responseData)
        guard let pdfData = decodeBase64URLData(decoded.data) else {
            throw GmailFetchError.decoding
        }
        return pdfData
    }

    // MARK: - Auth

    private static func currentAccessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw GmailFetchError.notSignedIn
        }
        return try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshedUser, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token = refreshedUser?.accessToken.tokenString {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: GmailFetchError.tokenUnavailable)
                }
            }
        }
    }

    // MARK: - Gmail REST calls

    private struct ListResponse: Decodable {
        struct MessageRef: Decodable { let id: String }
        let messages: [MessageRef]?
    }

    private static func listMessageIDs(query: String, accessToken: String) async throws -> [String] {
        var components = URLComponents(string: "\(apiBase)/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "25"),
        ]
        let data = try await get(components.url!, accessToken: accessToken)
        let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
        return decoded.messages?.map(\.id) ?? []
    }

    private struct MessageResponse: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String?; let attachmentId: String? }
        struct Part: Decodable {
            let mimeType: String?
            let filename: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Part]?
        }
        let id: String
        let snippet: String?
        let payload: Part?
    }

    private struct AttachmentResponse: Decodable {
        let data: String
    }

    private static func fetchMessage(id: String, accessToken: String) async throws -> GmailMessage? {
        let url = URL(string: "\(apiBase)/messages/\(id)?format=full")!
        let data = try await get(url, accessToken: accessToken)
        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)

        let subject = decoded.payload?.headers?
            .first { $0.name.caseInsensitiveCompare("Subject") == .orderedSame }?.value
            ?? "(no subject)"
        let bodyText = extractBodyText(from: decoded.payload) ?? decoded.snippet ?? ""

        return GmailMessage(id: decoded.id, subject: subject, snippet: decoded.snippet ?? "", bodyText: bodyText)
    }

    /// nil when the message has no PDF attachment at all (shouldn't happen
    /// given the `has:attachment filename:pdf` query, but a query match
    /// doesn't guarantee the MIME tree parses the way we expect it to).
    private static func fetchStatementSummary(id: String, accessToken: String) async throws -> GmailMessageSummary? {
        let url = URL(string: "\(apiBase)/messages/\(id)?format=full")!
        let data = try await get(url, accessToken: accessToken)
        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)

        guard let payload = decoded.payload,
              let attachment = findPDFAttachment(in: payload) else {
            return nil
        }

        func header(_ name: String) -> String? {
            decoded.payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        return GmailMessageSummary(
            id: decoded.id,
            subject: header("Subject") ?? "(no subject)",
            from: header("From") ?? "",
            dateString: header("Date") ?? "",
            attachmentID: attachment.attachmentID,
            attachmentFilename: attachment.filename
        )
    }

    /// Depth-first search of the MIME tree for the first PDF part — by
    /// declared mimeType, falling back to a ".pdf" filename for servers
    /// that mislabel the part's mimeType (seen from some bank mailers).
    private static func findPDFAttachment(in part: MessageResponse.Part) -> (attachmentID: String, filename: String)? {
        let looksLikePDF = part.mimeType == "application/pdf"
            || (part.filename?.lowercased().hasSuffix(".pdf") ?? false)
        if looksLikePDF, let attachmentID = part.body?.attachmentId {
            return (attachmentID, part.filename ?? "statement.pdf")
        }
        guard let children = part.parts else { return nil }
        for child in children {
            if let found = findPDFAttachment(in: child) { return found }
        }
        return nil
    }

    private static func get(_ url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GmailFetchError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw GmailFetchError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "unknown error")
        }
        return data
    }

    // MARK: - Body extraction

    /// Prefers a text/plain part anywhere in the MIME tree; falls back to the
    /// first text/html part (tags stripped) only if no plain-text part exists.
    private static func extractBodyText(from part: MessageResponse.Part?) -> String? {
        guard let part else { return nil }

        if let plainPart = findPart(in: part, mimeType: "text/plain"),
           let data = plainPart.body?.data, let decoded = decodeBase64URL(data) {
            return decoded
        }
        if let htmlPart = findPart(in: part, mimeType: "text/html"),
           let data = htmlPart.body?.data, let decoded = decodeBase64URL(data) {
            return stripHTMLTags(decoded)
        }
        // No nested parts at all — body lives directly on this part.
        if let data = part.body?.data, let decoded = decodeBase64URL(data) {
            return part.mimeType == "text/html" ? stripHTMLTags(decoded) : decoded
        }
        return nil
    }

    private static func findPart(in part: MessageResponse.Part, mimeType: String) -> MessageResponse.Part? {
        if part.mimeType == mimeType { return part }
        guard let children = part.parts else { return nil }
        for child in children {
            if let found = findPart(in: child, mimeType: mimeType) { return found }
        }
        return nil
    }

    private static func decodeBase64URL(_ string: String) -> String? {
        guard let data = decodeBase64URLData(string) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Gmail's message bodies and attachments are both base64url-encoded
    /// (RFC 4648 §5 — "-"/"_" instead of "+"/"/", padding stripped). This is
    /// the shared decode step; decodeBase64URL(_:) additionally interprets
    /// the result as UTF-8 text, which only makes sense for a message body,
    /// never for binary attachment content like a PDF.
    private static func decodeBase64URLData(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    /// Strips markup down to plain text. Only text/plain or text/html parts
    /// ever reach here (see extractBodyText/findPart) — image parts and
    /// attachments live in separate MIME parts that are never selected, and
    /// an <img> tag's alt text/src (including any inline base64 data: URI)
    /// is inside the tag itself, so the "<[^>]+>" strip below removes it
    /// along with the rest of the tag rather than leaking it as text.
    /// <script>/<style> blocks are the one thing that DOES leak that way —
    /// their content sits between the tags, not inside them — so those are
    /// dropped wholesale first; otherwise CSS/JS noise ends up looking like
    /// body text to both the pre-filter and the model.
    private static func stripHTMLTags(_ html: String) -> String {
        let withoutScriptsAndStyles = html.replacingOccurrences(
            of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        let withoutTags = withoutScriptsAndStyles.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let unescaped = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return unescaped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
