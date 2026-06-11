import Foundation

enum SpendCategory: String, Codable, CaseIterable, Identifiable {
    case food = "Food & Dining"
    case groceries = "Groceries"
    case transport = "Transport"
    case shopping = "Shopping"
    case entertainment = "Entertainment"
    case utilities = "Bills & Utilities"
    case health = "Health"
    case travel = "Travel"
    case education = "Education"
    case investment = "Investment"
    case transfer = "Transfers"
    case income = "Income"
    case other = "Other"

    var id: String { rawValue }

    /// Categories that represent money coming IN, excluded from spend analytics.
    static var spendCases: [SpendCategory] { allCases.filter { $0 != .income } }

    var icon: String {
        switch self {
        case .food: return "fork.knife"
        case .groceries: return "cart.fill"
        case .transport: return "car.fill"
        case .shopping: return "bag.fill"
        case .entertainment: return "tv.fill"
        case .utilities: return "bolt.fill"
        case .health: return "cross.case.fill"
        case .travel: return "airplane"
        case .education: return "book.fill"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .transfer: return "arrow.left.arrow.right"
        case .income: return "arrow.down.circle.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }
}

/// Direction of money flow. Absent (nil) means expense — keeps old saved data decodable.
enum TransactionKind: String, Codable { case expense, income }

struct Transaction: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var amount: Double          // INR; positive = debit (spend)
    var merchant: String
    var category: SpendCategory
    var bank: String            // e.g. "HDFC", "ICICI"
    var source: String          // "gmail" | "manual" | "sample"
    var rawSnippet: String?     // original email snippet, for debugging
    var account: String?        // Gmail address this came from (family member)
    var sourceID: String?       // stable provider id (Gmail message id); nil for manual/sample
    var kind: TransactionKind?  // nil == expense (back-compat with old saved data)

    var isIncome: Bool { kind == .income }

    var amountFormatted: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "INR"
        f.currencySymbol = "₹"
        f.maximumFractionDigits = amount.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return f.string(from: NSNumber(value: amount)) ?? "₹\(amount)"
    }
}

struct CategorySummary: Identifiable {
    var id: String { category.rawValue }
    let category: SpendCategory
    let total: Double
    let count: Int
    let percentOfSpend: Double
}
