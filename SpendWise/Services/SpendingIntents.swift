// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import AppIntents
import Foundation

/// Shared signal an App Intent sets to ask the app to open the animated Spending Story. The
/// root view observes this and presents the player. `nil` means "nothing requested".
@MainActor
final class StoryLaunchRequest: ObservableObject {
    static let shared = StoryLaunchRequest()
    @Published var period: StoryPeriod?
}

/// The period a Siri spending summary covers.
enum SpendingPeriodAppEnum: String, AppEnum {
    case thisMonth, lastMonth, last3Months, thisYear

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Period" }
    static var caseDisplayRepresentations: [SpendingPeriodAppEnum: DisplayRepresentation] {
        [.thisMonth: "This Month", .lastMonth: "Last Month",
         .last3Months: "Last 3 Months", .thisYear: "This Year"]
    }

    var storyPeriod: StoryPeriod {
        switch self {
        case .thisMonth:   return .thisMonth
        case .lastMonth:   return .lastMonth
        case .last3Months: return .last3Months
        case .thisYear:    return .thisYear
        }
    }
}

/// "Hey Siri, describe my spending in SpendWise." Computes a quick on-device summary from the
/// user's own data and speaks it back. Deterministic (no network, no model load) so it's fast
/// and works even when Siri runs it in the background.
struct DescribeSpendingIntent: AppIntent {
    static var title: LocalizedStringResource = "Describe My Spending"
    static var description = IntentDescription("Hear a quick summary of how much you've spent.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Period", default: .thisMonth)
    var period: SpendingPeriodAppEnum

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TransactionStore()
        let data = StoryDataBuilder.build(period: period.storyPeriod, expenses: store.visibleExpenses)
        return .result(dialog: IntentDialog(stringLiteral: Self.spokenSummary(data)))
    }

    static func spokenSummary(_ d: StoryData) -> String {
        guard !d.isEmpty else {
            return "You have no spending recorded for \(d.period.title.lowercased()) yet."
        }
        func rupees(_ v: Double) -> String { "\(Int(v).formatted()) rupees" }

        var parts = ["\(d.period.title), you've spent \(rupees(d.total)) across \(d.txCount) transactions."]
        if let pct = d.deltaPercent {
            let dir = pct >= 0 ? "up" : "down"
            parts.append("That's \(dir) \(abs(Int(pct.rounded()))) percent from the previous period.")
        }
        if let top = d.topCategories.first {
            parts.append("Your biggest category is \(top.name) at \(rupees(top.total)), about \(Int(top.percent)) percent.")
        }
        if d.familySent > 0 { parts.append("You've sent \(rupees(d.familySent)) to family.") }
        return parts.joined(separator: " ")
    }
}

/// "Hey Siri, read my spending story in SpendWise." Apple Intelligence writes the full,
/// flowing narrative (the same one the video uses) and Siri reads it aloud — no screen needed.
/// Falls back to a deterministic narrative when Apple Intelligence is unavailable.
struct ReadSpendingStoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Read My Spending Story"
    static var description = IntentDescription("Apple Intelligence writes your spending story and Siri reads it aloud.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Period", default: .thisMonth)
    var period: SpendingPeriodAppEnum

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TransactionStore()
        let data = StoryDataBuilder.build(period: period.storyPeriod, expenses: store.visibleExpenses)
        guard !data.isEmpty else {
            return .result(dialog: "You have no spending recorded for \(data.period.title.lowercased()) yet.")
        }
        let (n, _) = await AIStoryNarrationService().narrate(data)
        // Stitch the scene lines into one flowing narrative (skip scenes with no data).
        let script = [
            n.opening, n.total, n.categories,
            data.trend.count > 1 ? n.trend : "",
            data.hasTransfers ? n.transfers : "",
            n.closing,
        ].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
         .joined(separator: " ")
        return .result(dialog: IntentDialog(stringLiteral: script))
    }
}

/// "Hey Siri, show my spending story in SpendWise." Opens the app and auto-plays the full
/// animated, narrated story video for the chosen period.
struct ShowSpendingStoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Show My Spending Story"
    static var description = IntentDescription("Opens SpendWise and plays your animated spending story.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Period", default: .thisMonth)
    var period: SpendingPeriodAppEnum

    @MainActor
    func perform() async throws -> some IntentResult {
        StoryLaunchRequest.shared.period = period.storyPeriod
        return .result()
    }
}

/// Registers the Siri phrases so the user can trigger these by voice.
struct SpendWiseAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DescribeSpendingIntent(),
            phrases: [
                "Describe my spending in \(.applicationName)",
                "How much have I spent in \(.applicationName)",
                "What's my spending in \(.applicationName)",
                "\(.applicationName) spending summary",
            ],
            shortTitle: "Describe Spending",
            systemImageName: "indianrupeesign.circle.fill"
        )
        AppShortcut(
            intent: ReadSpendingStoryIntent(),
            phrases: [
                "Read my spending story in \(.applicationName)",
                "Tell me my \(.applicationName) story",
            ],
            shortTitle: "Read Spending Story",
            systemImageName: "speaker.wave.2.fill"
        )
        AppShortcut(
            intent: ShowSpendingStoryIntent(),
            phrases: [
                "Show my spending story in \(.applicationName)",
                "Play my spending story in \(.applicationName)",
                "Watch my \(.applicationName) story",
            ],
            shortTitle: "Show Spending Story",
            systemImageName: "play.rectangle.on.rectangle.fill"
        )
    }
}
