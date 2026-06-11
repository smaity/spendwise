// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import FoundationModels

/// Conversational Q&A over the user's own spending, powered by Apple Intelligence
/// (Foundation Models, iOS 26+). The model is grounded with a precomputed digest of the
/// data (exact per-category / per-month / per-merchant totals) so its answers read off real
/// numbers instead of doing arithmetic over raw rows. One session is kept per conversation
/// so follow-up questions retain context.
///
/// FoundationModels is weak-linked: every use is guarded by `#available(iOS 26.0, *)`.
/// The live `LanguageModelSession` (iOS 26-only) is stored type-erased so this class can be
/// held by the iOS 17+ UI.
final class AIQueryService {

    private var sessionBox: AnyObject?

    /// Whether the on-device model can run right now. Logs the reason when it can't.
    func isAvailable() -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        case .unavailable(let reason):
            NSLog("SPENDWISE_AI: query unavailable — \(String(describing: reason))")
            return false
        @unknown default:
            return false
        }
    }

    /// Starts a fresh conversation grounded in the given transactions. Call when the Ask
    /// sheet opens (and whenever the underlying data/filter changes).
    func startConversation(with transactions: [Transaction]) {
        guard #available(iOS 26.0, *),
              case .available = SystemLanguageModel.default.availability else { sessionBox = nil; return }
        sessionBox = LanguageModelSession(instructions: Self.instructions(digest: Self.digest(for: transactions)))
    }

    /// Answers one question. Returns nil if Apple Intelligence is unavailable or errors.
    func ask(_ question: String) async -> String? {
        guard #available(iOS 26.0, *), let session = sessionBox as? LanguageModelSession else { return nil }
        do {
            return try await session.respond(to: question).content
        } catch {
            NSLog("SPENDWISE_AI: query error — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Grounding

    private static func instructions(digest: String) -> String {
        """
        You are SpendWise's spending assistant. Answer the user's questions about THEIR OWN
        spending using only the data digest below (amounts are in Indian Rupees, ₹). Be concise
        and specific — quote the relevant figures. If the digest doesn't contain the answer, say
        so plainly rather than guessing. You may suggest practical ways to save, but do not give
        regulated investment advice or recommend specific securities. Today's data:

        \(digest)
        """
    }

    /// A compact but thorough digest: totals, per-category and per-month breakdowns, top
    /// merchants, and detected subscriptions.
    static func digest(for txs: [Transaction], referenceDate: Date = Date()) -> String {
        guard !txs.isEmpty else { return "No transactions recorded yet." }
        let cal = Calendar.current
        let total = txs.reduce(0) { $0 + $1.amount }

        func monthKey(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d }
        let thisStart = monthKey(referenceDate)
        let lastStart = cal.date(byAdding: .month, value: -1, to: thisStart) ?? thisStart
        let thisMonth = txs.filter { monthKey($0.date) == thisStart }.reduce(0) { $0 + $1.amount }
        let lastMonth = txs.filter { monthKey($0.date) == lastStart }.reduce(0) { $0 + $1.amount }

        // Per-category, all time (with this-month split).
        let byCat = Dictionary(grouping: txs, by: \.category)
        let catLines = byCat
            .map { (cat, items) -> (String, Double) in
                (cat.rawValue, items.reduce(0) { $0 + $1.amount })
            }
            .sorted { $0.1 > $1.1 }
            .map { name, amt -> String in
                let tm = byCat.first { $0.key.rawValue == name }?.value
                    .filter { monthKey($0.date) == thisStart }.reduce(0) { $0 + $1.amount } ?? 0
                return "  - \(name): ₹\(Int(amt)) total, ₹\(Int(tm)) this month"
            }
            .joined(separator: "\n")

        // Monthly totals (most recent 12).
        let byMonth = Dictionary(grouping: txs, by: { monthKey($0.date) })
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.0 > $1.0 }
            .prefix(12)
        let monthFmt = Date.FormatStyle().month(.abbreviated).year()
        let monthLines = byMonth.map { "  - \($0.0.formatted(monthFmt)): ₹\(Int($0.1))" }.joined(separator: "\n")

        // Top merchants, all time.
        let merchantLines = Dictionary(grouping: txs, by: \.merchant)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map { "  - \($0.0): ₹\(Int($0.1)) across \($0.2) transaction(s)" }
            .joined(separator: "\n")

        // Subscriptions (recurring fixed charges).
        let subs = InsightsEngine.repeatedSpends(for: txs, limit: 30).filter(\.isSubscription)
        let subLines = subs.isEmpty
            ? "  - none detected"
            : subs.map { "  - \($0.merchant): ~₹\(Int($0.average))/charge" }.joined(separator: "\n")

        let span = (txs.map(\.date).min(), txs.map(\.date).max())
        let spanText = [span.0, span.1].compactMap { $0 }
            .map { $0.formatted(date: .abbreviated, time: .omitted) }.joined(separator: " to ")

        return """
        Overall: ₹\(Int(total)) across \(txs.count) transactions (\(spanText)).
        This month: ₹\(Int(thisMonth)). Last month: ₹\(Int(lastMonth)).

        Spend by category (total, then this month):
        \(catLines)

        Monthly totals:
        \(monthLines)

        Top merchants:
        \(merchantLines)

        Subscriptions:
        \(subLines)
        """
    }
}
