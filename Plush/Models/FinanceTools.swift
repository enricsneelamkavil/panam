import FoundationModels
import Foundation
import SwiftData

// MARK: - Shared helpers (pure computation — safe off the main actor)

private nonisolated func inr(_ value: Double) -> String {
    value.formatted(.currency(code: "INR").locale(Locale(identifier: "en_IN")))
}

private nonisolated func fetchAll<T: PersistentModel>(_ type: T.Type, from context: ModelContext) -> [T] {
    (try? context.fetch(FetchDescriptor<T>())) ?? []
}

/// Half-open [start, end) interval for the named period — same Calendar
/// anchoring the dashboards use.
private nonisolated func periodInterval(_ period: String) -> DateInterval? {
    let calendar = Calendar.current
    let now = Date.now
    let todayStart = calendar.startOfDay(for: now)
    switch period {
    case "today":
        guard let end = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
        return DateInterval(start: todayStart, end: end)
    case "yesterday":
        guard let start = calendar.date(byAdding: .day, value: -1, to: todayStart) else { return nil }
        return DateInterval(start: start, end: todayStart)
    case "thisWeek":
        return calendar.dateInterval(of: .weekOfYear, for: now)
    case "thisMonth":
        return calendar.dateInterval(of: .month, for: now)
    case "lastMonth":
        guard let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
        return calendar.dateInterval(of: .month, for: lastMonth)
    case "thisYear":
        return calendar.dateInterval(of: .year, for: now)
    default:
        return nil
    }
}

private nonisolated func dueLabel(for date: Date) -> String {
    let formatted = date.formatted(date: .abbreviated, time: .omitted)
    return date < Calendar.current.startOfDay(for: .now)
        ? "overdue since \(formatted)"
        : "due \(formatted)"
}

// MARK: - Tools

nonisolated struct SpendSummaryTool: Tool {
    let name = "getSpendSummary"
    let description = "Get total income and expense for a time period, optionally filtered by category name"
    let modelContainer: ModelContainer

    @Generable
    struct Arguments {
        @Guide(description: "One of: today, yesterday, thisWeek, thisMonth, lastMonth, thisYear")
        var period: String
        @Guide(description: "Exact category name to filter by, or nil for all categories")
        var categoryName: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let context = ModelContext(modelContainer)

        guard let interval = periodInterval(arguments.period) else {
            return "Unknown period '\(arguments.period)'. Valid values: today, yesterday, thisWeek, thisMonth, lastMonth, thisYear."
        }

        var relevant = fetchAll(Transaction.self, from: context)
            .filter { $0.date >= interval.start && $0.date < interval.end }
        if let categoryName = arguments.categoryName, !categoryName.isEmpty {
            relevant = relevant.filter {
                $0.category?.name.compare(categoryName, options: .caseInsensitive) == .orderedSame
            }
        }

        let income = relevant.filter { $0.type == .income }.reduce(0) { $0 + $1.amount }
        let expense = relevant.filter { $0.type == .expense }.reduce(0) { $0 + $1.amount }
        let filterNote = arguments.categoryName.map { " in category '\($0)'" } ?? ""
        return "For \(arguments.period)\(filterNote): income \(inr(income)), expense \(inr(expense)), net \(inr(income - expense)), across \(relevant.count) transaction(s)."
    }
}

nonisolated struct SubscriptionTotalTool: Tool {
    let name = "getSubscriptionTotal"
    let description = "Get total monthly-equivalent subscription spend and list of active subscriptions with cost per day"
    let modelContainer: ModelContainer

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let context = ModelContext(modelContainer)

        let subscriptions = fetchAll(RecurringPayment.self, from: context)
            .filter { $0.isSubscription && $0.isActive }
        guard !subscriptions.isEmpty else { return "No active subscriptions." }

        let total = subscriptions.reduce(0) { $0 + $1.monthlyEquivalentCost }
        var lines = ["Total monthly-equivalent subscription spend: \(inr(total))."]
        for subscription in subscriptions.sorted(by: { $0.costPerDay > $1.costPerDay }) {
            lines.append("\(subscription.name): \(inr(subscription.costPerDay))/day (\(subscription.cadence.displayName) \(inr(subscription.expectedAmount)))")
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated struct UpcomingDuesTool: Tool {
    let name = "getUpcomingDues"
    let description = "Get bills, subscriptions, EMIs, and investment contributions due or overdue within the next N days"
    let modelContainer: ModelContainer

    @Generable
    struct Arguments {
        @Guide(description: "Number of days to look ahead, default 7 if not specified")
        var days: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let context = ModelContext(modelContainer)

        let days = arguments.days ?? 7
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        guard let windowEnd = calendar.date(byAdding: .day, value: days, to: todayStart) else {
            return "Invalid day range."
        }

        var lines: [String] = []

        // Same filter as the dashboard's Upcoming Dues: unpaid,
        // reminder-eligible (non-daily), due within the window or overdue.
        let bills = fetchAll(RecurringOccurrence.self, from: context)
            .filter {
                !$0.isPaid && ($0.parent?.cadence.reminderEligible ?? false)
                    && calendar.startOfDay(for: $0.dueDate) <= windowEnd
            }
            .sorted { $0.dueDate < $1.dueDate }
        for occurrence in bills {
            let kind = occurrence.parent?.isSubscription == true ? "Subscription" : "Bill"
            lines.append("\(kind) — \(occurrence.parent?.name ?? "Recurring"): \(inr(occurrence.expectedAmount)) \(dueLabel(for: occurrence.dueDate))")
        }

        let contributions = fetchAll(InvestmentOccurrence.self, from: context)
            .filter {
                !$0.isContributed && $0.parent?.cadence != .daily
                    && calendar.startOfDay(for: $0.dueDate) <= windowEnd
            }
            .sorted { $0.dueDate < $1.dueDate }
        for occurrence in contributions {
            lines.append("Investment — \(occurrence.parent?.name ?? "SIP"): \(inr(occurrence.expectedAmount)) \(dueLabel(for: occurrence.dueDate))")
        }

        let installments = fetchAll(EMIInstallment.self, from: context)
            .filter { !$0.isPaid && calendar.startOfDay(for: $0.dueDate) <= windowEnd }
            .sorted { $0.dueDate < $1.dueDate }
        for installment in installments {
            let emiName = installment.parent?.name ?? "EMI"
            let tenure = installment.parent?.tenureMonths ?? 0
            lines.append("EMI — \(emiName) (\(installment.installmentNumber)/\(tenure)): \(inr(installment.amount)) \(dueLabel(for: installment.dueDate))")
        }

        guard !lines.isEmpty else {
            return "Nothing due or overdue within the next \(days) day(s)."
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated struct NetWorthTool: Tool {
    let name = "getNetWorth"
    let description = "Get current net worth (bank + cash accounts) and total credit card outstanding separately"
    let modelContainer: ModelContainer

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let context = ModelContext(modelContainer)

        let accounts = fetchAll(Account.self, from: context)
        // Same split as the detailed dashboard: cards are excluded from
        // net worth and reported separately.
        let bankCash = accounts.filter { $0.type != .creditCard }.reduce(0) { $0 + $1.balance }
        let cardOutstanding = accounts.filter { $0.type == .creditCard }.reduce(0) { $0 + $1.balance }
        return "Net worth (bank + cash + wallets): \(inr(bankCash)). Total credit card outstanding (not part of net worth): \(inr(cardOutstanding))."
    }
}

nonisolated struct AccountBalanceTool: Tool {
    let name = "getAccountBalance"
    let description = "Get the balance or outstanding amount for a specific named account or credit card"
    let modelContainer: ModelContainer

    @Generable
    struct Arguments {
        @Guide(description: "Exact account name")
        var accountName: String
    }

    func call(arguments: Arguments) async throws -> String {
        let context = ModelContext(modelContainer)

        let accounts = fetchAll(Account.self, from: context)
        guard let account = accounts.first(where: {
            $0.name.compare(arguments.accountName, options: .caseInsensitive) == .orderedSame
        }) else {
            let available = accounts.map(\.name).joined(separator: ", ")
            return "No account named '\(arguments.accountName)'. Available accounts: \(available)."
        }

        guard account.type == .creditCard else {
            return "\(account.name): balance \(inr(account.balance))."
        }

        var parts = ["\(account.name) (credit card): outstanding \(inr(account.balance))"]
        if let limit = account.creditLimit, limit > 0 {
            let utilization = (account.balance / limit).formatted(.percent.precision(.fractionLength(0)))
            parts.append("limit \(inr(limit)), utilization \(utilization)")
        }
        if let statementDay = account.statementDay {
            parts.append("statement on day \(statementDay) of the month")
        }
        if let dueDay = account.dueDay {
            parts.append("payment due on day \(dueDay) of the month")
        }
        return parts.joined(separator: "; ") + "."
    }
}

nonisolated struct LendingBalanceTool: Tool {
    let name = "getLendingBalance"
    let description = "Get how much is owed to the user or by the user, overall or for a specific person"
    let modelContainer: ModelContainer

    @Generable
    struct Arguments {
        @Guide(description: "Exact person name to filter by, or nil for the overall totals across everyone")
        var personName: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let context = ModelContext(modelContainer)

        let people = fetchAll(Person.self, from: context)

        if let personName = arguments.personName, !personName.isEmpty {
            guard let person = people.first(where: {
                $0.name.compare(personName, options: .caseInsensitive) == .orderedSame
            }) else {
                return "No person named '\(personName)' in the lending ledger."
            }
            let balance = person.netBalance
            if balance > 0 {
                return "\(person.name) owes you \(inr(balance))."
            } else if balance < 0 {
                return "You owe \(person.name) \(inr(-balance))."
            }
            return "You and \(person.name) are settled — nothing outstanding."
        }

        let owedToYou = people.map(\.netBalance).filter { $0 > 0 }.reduce(0, +)
        let youOwe = -people.map(\.netBalance).filter { $0 < 0 }.reduce(0, +)
        return "Across \(people.count) people: owed to you \(inr(owedToYou)), you owe \(inr(youOwe))."
    }
}

nonisolated struct InvestmentTotalTool: Tool {
    let name = "getInvestmentTotal"
    let description = "Get total amount invested, broken down by instrument type"
    let modelContainer: ModelContainer

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let context = ModelContext(modelContainer)

        let investments = fetchAll(Investment.self, from: context)
        guard !investments.isEmpty else { return "No investments recorded." }

        // investedValue = lumpsum amounts + actually-contributed SIP amounts,
        // identical to the Investments tab totals.
        let total = investments.reduce(0) { $0 + $1.investedValue }
        var lines = ["Total invested: \(inr(total))."]
        for type in InstrumentType.allCases {
            let typeTotal = investments
                .filter { $0.instrumentType == type }
                .reduce(0) { $0 + $1.investedValue }
            if typeTotal > 0 {
                lines.append("\(type.displayName): \(inr(typeTotal))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
