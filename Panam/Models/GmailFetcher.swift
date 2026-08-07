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
        struct Body: Decodable { let data: String? }
        struct Part: Decodable {
            let mimeType: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Part]?
        }
        let id: String
        let snippet: String?
        let payload: Part?
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
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func stripHTMLTags(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
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
