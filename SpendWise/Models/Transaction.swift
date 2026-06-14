// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

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
    var toFamily: Bool?         // set by the family-transfer detector; nil == not yet checked
    var familyMember: String?   // which family member this transfer matched, when toFamily == true
    var recipientAccountLast4: String?  // destination account's last 4 digits, for deterministic family matching
    var isSelfTransfer: Bool?   // true == a move between the user's own accounts (still counted as spend, just tagged)
    var modifiedAt: Date?       // last local mutation; tie-breaks CloudKit field-merge conflicts (nil == legacy/oldest)
    var altSourceID: String?    // secondary provider id when the SAME txn arrived via two channels (e.g. gmail + sms)
    var referenceID: String?    // bank reference / UPI ref / UTR — identical across channels for one payment, so the reliable dedup key

    var isIncome: Bool { kind == .income }

    /// All stable provider ids this row carries (primary + cross-channel secondary).
    var sourceIDs: [String] { [sourceID, altSourceID].compactMap { $0 } }

    /// A person-to-person money transfer (vs. a merchant purchase).
    var isTransfer: Bool { category == .transfer }

    /// A move between the user's OWN accounts — counted as neither income nor spending (it nets
    /// to zero). Set by `detectSelfTransfers`.
    var isSelf: Bool { isSelfTransfer == true }

    /// Money put into a brokerage/fund (still counted as spending, and shown on its own card too).
    var isInvestment: Bool { !isIncome && !isSelf && category == .investment }

    /// Spending — the basis for spending analytics. All money that left your hands: consumption,
    /// transfers to people, AND investments. Excludes only income and self-transfers (moves
    /// between your OWN accounts, which net to zero).
    var isConsumption: Bool {
        !isIncome && !isSelf
    }

    var amountFormatted: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "INR"
        f.currencySymbol = "₹"
        f.maximumFractionDigits = amount.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return f.string(from: NSNumber(value: amount)) ?? "₹\(amount)"
    }
}

/// A line on the income & expenditure statement (an income source or a spending category).
struct StatementLine: Identifiable {
    var id: String { name }
    let name: String
    let amount: Double
    let icon: String
}

/// A simple income & expenditure statement (receipts and payments), for a period.
struct FinancialStatement {
    let period: ClosedRange<Date>?
    let income: Double
    let incomeLines: [StatementLine]
    let expenditure: Double
    let expenditureLines: [StatementLine]
    var net: Double { income - expenditure }   // surplus (+) or deficit (−)
}

struct CategorySummary: Identifiable {
    var id: String { category.rawValue }
    let category: SpendCategory
    let total: Double
    let count: Int
    let percentOfSpend: Double
}

