import Foundation
import FoundationModels
import SwiftData

enum FinanceChatError: LocalizedError {
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): reason
        }
    }
}

/// A chat session over the user's finance data. All numbers come from the
/// read-only tools; the model itself can't touch the store.
@MainActor
final class FinanceChatSession {
    private let session: LanguageModelSession

    init(modelContext: ModelContext) {
        let todayString = Date.now.formatted(date: .complete, time: .omitted)
        let instructions = """
            You are Plush's personal finance assistant. Today's date is \(todayString).

            Answer questions about the user's personal finance data only by \
            calling the provided tools. Never fabricate numbers that were not \
            returned by a tool call — if no tool can answer the question, say so.

            You cannot create, edit, or delete any data, and must never claim \
            to have done so.

            Keep answers short and lead with the numbers. Amounts are in \
            Indian rupees.
            """

        session = LanguageModelSession(
            tools: [
                SpendSummaryTool(modelContainer: modelContext.container),
                SubscriptionTotalTool(modelContainer: modelContext.container),
                UpcomingDuesTool(modelContainer: modelContext.container),
                NetWorthTool(modelContainer: modelContext.container),
                AccountBalanceTool(modelContainer: modelContext.container),
                LendingBalanceTool(modelContainer: modelContext.container),
                InvestmentTotalTool(modelContainer: modelContext.container),
            ],
            instructions: instructions
        )
    }

    func send(_ message: String) async throws -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw FinanceChatError.modelUnavailable("This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw FinanceChatError.modelUnavailable("Turn on Apple Intelligence in Settings to use chat.")
        case .unavailable(.modelNotReady):
            throw FinanceChatError.modelUnavailable("The on-device model isn't ready yet. Try again in a bit.")
        case .unavailable:
            throw FinanceChatError.modelUnavailable("The on-device model is unavailable.")
        }
        return try await session.respond(to: message).content
    }
}
