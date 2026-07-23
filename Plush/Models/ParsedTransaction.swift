import FoundationModels

@Generable
struct ParsedTransaction {
    @Guide(description: "The transaction amount as a positive number")
    var amount: Double

    @Guide(description: "Either 'expense' or 'income'")
    var type: String

    @Guide(description: "The closest matching category name from the provided list, or nil if unclear")
    var categoryName: String?

    @Guide(description: "The closest matching account name from the provided list, or nil if unclear")
    var accountName: String?

    @Guide(description: "A short note capturing any extra detail mentioned, or nil")
    var note: String?
}
