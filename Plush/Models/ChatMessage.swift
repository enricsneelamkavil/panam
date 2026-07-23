import Foundation

/// One chat bubble. Deliberately not a SwiftData model — chat history
/// doesn't persist across launches.
struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user, assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date = .now
}
