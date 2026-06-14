// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import FoundationModels

/// The spoken/caption script for a Spending Story — one short line per scene. Plain (non-
/// `@Generable`) so the iOS 17+ UI can hold it. Produced by Apple Intelligence when available,
/// else by a deterministic fallback so the feature still plays (and tests) without AI.
struct StoryNarration {
    var title: String
    var opening: String
    var total: String
    var categories: String
    var trend: String
    var transfers: String
    var closing: String

    /// Built straight from the numbers — used in the Simulator and any time Apple Intelligence
    /// is unavailable. Reads naturally when spoken: amounts as "12,500 rupees", no ₹ symbol.
    static func fallback(from d: StoryData) -> StoryNarration {
        func rupees(_ v: Double) -> String { "\(Int(v).formatted()) rupees" }

        let deltaLine: String
        if let pct = d.deltaPercent {
            let dir = pct >= 0 ? "up" : "down"
            deltaLine = " That's \(dir) \(abs(Int(pct.rounded()))) percent from the previous period."
        } else {
            deltaLine = ""
        }

        let catLine: String
        if let top = d.topCategories.first {
            let second = d.topCategories.dropFirst().first
            let secondPart = second.map { ", followed by \($0.name)" } ?? ""
            catLine = "\(top.name) led the way at \(rupees(top.total)), about \(Int(top.percent)) percent of everything\(secondPart)."
        } else {
            catLine = "There wasn't much spending to break down this time."
        }

        let trendLine: String
        if let peak = d.peakTrend, d.trend.count > 1 {
            trendLine = "Your busiest stretch was \(peak.label), when you spent \(rupees(peak.total))."
        } else {
            trendLine = "Spending stayed fairly steady across the period."
        }

        var transferLine = ""
        if d.familySent > 0 && d.selfTransfers > 0 {
            transferLine = "You sent \(rupees(d.familySent)) to family and moved \(rupees(d.selfTransfers)) between your own accounts."
        } else if d.familySent > 0 {
            transferLine = "You sent \(rupees(d.familySent)) to family during this period."
        } else if d.selfTransfers > 0 {
            transferLine = "You moved \(rupees(d.selfTransfers)) between your own accounts."
        }

        let closing = d.deltaPercent.map { $0 > 5
            ? "Spending crept up a bit — picking one category to trim next period could make a real difference. You've got this."
            : "Nicely managed. Keep an eye on your top category and you'll stay on track." }
            ?? "Keep tracking, and you'll always know exactly where your money goes."

        return StoryNarration(
            title: "Your \(d.period.title) Money Story",
            opening: "Here's your \(d.period.title.lowercased()) spending story, made just for you.",
            total: "You spent \(rupees(d.total)) across \(d.txCount) transactions.\(deltaLine)",
            categories: catLine,
            trend: trendLine,
            transfers: transferLine,
            closing: closing
        )
    }
}

/// Writes a Spending Story narration with Apple Intelligence's on-device model
/// (Foundation Models, iOS 26+). Returns the deterministic fallback when AI is unavailable.
///
/// FoundationModels is weak-linked: every use is guarded by `#available(iOS 26.0, macOS 26.0, *)`.
final class AIStoryNarrationService {

    func isAvailable() -> Bool {
        guard #available(iOS 26.0, macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Returns `(narration, isAI)`. Never throws — falls back to the deterministic script.
    func narrate(_ data: StoryData) async -> (StoryNarration, Bool) {
        guard #available(iOS 26.0, macOS 26.0, *),
              case .available = SystemLanguageModel.default.availability else {
            return (.fallback(from: data), false)
        }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let result = try await session.respond(to: data.digest, generating: AIStoryScript.self).content
            let n = StoryNarration(
                title: clean(result.title, fallback: "Your \(data.period.title) Money Story"),
                opening: result.opening, total: result.total, categories: result.categories,
                trend: result.trend, transfers: result.transfers, closing: result.closing)
            return (n, true)
        } catch {
            NSLog("SPENDWISE_AI: story narration error — \(error.localizedDescription)")
            return (.fallback(from: data), false)
        }
    }

    private func clean(_ s: String, fallback: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }

    private static let instructions = """
    You are a warm, upbeat narrator for SpendWise, a private on-device spending tracker for an
    Indian user. You are given a digest of their spending for a period (amounts in Indian
    Rupees). Write a short, friendly voice-over script for an animated recap — like a personal
    "year in review", but for this period.

    Rules:
    - Each field is ONE or TWO short spoken sentences. Conversational and encouraging, never
      preachy or judgmental.
    - Speak amounts as a number followed by the word "rupees" (e.g. "12,500 rupees"). NEVER use
      the ₹ symbol or the word "INR".
    - Use ONLY the numbers in the digest. Do not invent merchants, categories, or figures.
    - Address the user as "you". Keep it natural to read aloud.
    - Do NOT give regulated investment advice or recommend specific securities.
    """
}

/// Guided-generation shape Apple Intelligence fills in. iOS 26+ only.
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct AIStoryScript {
    @Guide(description: "A catchy title for this spending recap, at most 5 words.")
    var title: String
    @Guide(description: "One warm spoken sentence welcoming the user to their spending recap for the period.")
    var opening: String
    @Guide(description: "One or two spoken sentences stating the total spent and how it compares to the previous period.")
    var total: String
    @Guide(description: "One or two spoken sentences on the top spending categories and the largest party or purchase.")
    var categories: String
    @Guide(description: "One spoken sentence about the spending trend or the busiest stretch of the period.")
    var trend: String
    @Guide(description: "One spoken sentence about money sent to family or moved between own accounts. Empty string if there was none.")
    var transfers: String
    @Guide(description: "One encouraging spoken closing line with a single practical, non-preachy money tip.")
    var closing: String
}
