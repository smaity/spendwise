// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import FoundationModels

/// A natural-language spending summary + tips, produced by Apple Intelligence.
/// Plain (non-`@Generable`) so the UI, which targets iOS 17+, can hold it.
struct SpendingInsight {
    let summary: String
    let tips: [String]
}

/// Generates personalized spending insights with Apple Intelligence's on-device model
/// (Foundation Models, iOS 26+). Returns nil when Apple Intelligence is unavailable, so the
/// UI simply hides the AI section and keeps the rule-based insights.
///
/// FoundationModels is weak-linked: every use is guarded by `#available(iOS 26.0, macOS 26.0, *)`.
final class AIInsightsService {

    /// Whether the on-device model can run right now. Logs the reason when it can't.
    func isAvailable() -> Bool {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            NSLog("SPENDWISE_AI: OS < 26 — Apple Intelligence unavailable")
            return false
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        case .unavailable(let reason):
            NSLog("SPENDWISE_AI: insights unavailable — \(String(describing: reason))")
            return false
        @unknown default:
            return false
        }
    }

    /// Turns a compact spending summary into a friendly overview + 3 actionable tips.
    func generate(spendingSummary: String) async -> SpendingInsight? {
        guard #available(iOS 26.0, macOS 26.0, *),
              case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(to: spendingSummary, generating: AIGeneratedInsight.self)
            let content = response.content
            return SpendingInsight(summary: content.summary, tips: content.tips)
        } catch {
            NSLog("SPENDWISE_AI: insights error — \(error.localizedDescription)")
            return nil
        }
    }

    private static let instructions = """
    You are a friendly personal-finance assistant for an Indian user of a spending-tracker app.
    You are given a compact summary of this month's spending (amounts in Indian Rupees, ₹).
    Write a warm, concrete 2–3 sentence overview of how they spent this month (reference real
    categories and merchants and the month-over-month change), then give 3 short, specific,
    practical money-saving tips grounded in the numbers (e.g. cutting food delivery, cancelling
    unused subscriptions, cheaper transport). Keep it encouraging, not preachy. Do NOT give
    regulated investment advice or recommend specific securities.
    """
}

/// Guided-generation shape Apple Intelligence fills in. iOS 26+ only.
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct AIGeneratedInsight {
    @Guide(description: "A warm 2-3 sentence overview of this month's spending, referencing real categories, merchants, and the month-over-month change.")
    var summary: String

    @Guide(description: "Exactly 3 short, specific, actionable money-saving tips grounded in the spending data.")
    var tips: [String]
}
