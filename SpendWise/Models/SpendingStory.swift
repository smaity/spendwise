// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation

/// A period the user can recap as a "Spending Story".
enum StoryPeriod: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, last3Months, last6Months, thisYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMonth:   return "This month"
        case .lastMonth:   return "Last month"
        case .last3Months: return "Last 3 months"
        case .last6Months: return "Last 6 months"
        case .thisYear:    return "This year"
        }
    }

    /// True for single-calendar-month periods — these get a weekly trend; the rest, monthly.
    var isSingleMonth: Bool { self == .thisMonth || self == .lastMonth }

    /// The period's date window plus the equivalent preceding window (for "vs. last period").
    func ranges(now: Date = Date(), calendar: Calendar = .current) -> (current: Range<Date>, prior: Range<Date>) {
        let cal = calendar
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        func month(_ delta: Int) -> Date { cal.date(byAdding: .month, value: delta, to: monthStart) ?? monthStart }
        switch self {
        case .thisMonth:
            return (month(0)..<now, month(-1)..<month(0))
        case .lastMonth:
            return (month(-1)..<month(0), month(-2)..<month(-1))
        case .last3Months:
            return (month(-2)..<now, month(-5)..<month(-2))
        case .last6Months:
            return (month(-5)..<now, month(-11)..<month(-5))
        case .thisYear:
            let yearStart = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
            let priorStart = cal.date(byAdding: .year, value: -1, to: yearStart) ?? yearStart
            let priorEnd = cal.date(byAdding: .year, value: -1, to: now) ?? now
            return (yearStart..<now, priorStart..<priorEnd)
        }
    }
}

/// Everything the story's visuals and narration are built from — computed purely from the
/// user's transactions for the chosen period. No AI here; this is the ground truth.
struct StoryData {
    let period: StoryPeriod
    let total: Double
    let priorTotal: Double
    let txCount: Int
    let dayCount: Int
    let topCategories: [CategorySlice]      // up to 5, largest first
    let topMerchant: NamedAmount?           // biggest party by total
    let biggestPurchase: NamedAmount?       // largest single non-transfer expense
    let trend: [TrendPoint]                 // weekly (single month) or monthly buckets
    let familySent: Double
    let selfTransfers: Double

    struct CategorySlice: Identifiable { let id = UUID(); let name: String; let icon: String; let total: Double; let percent: Double }
    struct NamedAmount { let name: String; let amount: Double }
    struct TrendPoint: Identifiable { let id = UUID(); let date: Date; let label: String; let total: Double }

    var perDay: Double { dayCount > 0 ? total / Double(dayCount) : 0 }

    /// Percent change vs. the preceding period. nil when there's no prior baseline.
    var deltaPercent: Double? {
        guard priorTotal > 0 else { return nil }
        return (total - priorTotal) / priorTotal * 100
    }

    var hasTransfers: Bool { familySent > 0 || selfTransfers > 0 }
    var isEmpty: Bool { txCount == 0 }
    var peakTrend: TrendPoint? { trend.max { $0.total < $1.total } }

    /// A compact, model-friendly digest handed to Apple Intelligence to write the narration.
    var digest: String {
        let cats = topCategories.map { "\($0.name) \(Int($0.total)) rupees (\(Int($0.percent))%)" }.joined(separator: ", ")
        let delta = deltaPercent.map { d in
            let dir = d >= 0 ? "up" : "down"
            return "\(dir) \(abs(Int(d)))% vs the previous period (\(Int(priorTotal)) rupees)"
        } ?? "no comparable previous period"
        var lines = [
            "Period: \(period.title).",
            "Total spent: \(Int(total)) rupees across \(txCount) transactions over \(dayCount) days (about \(Int(perDay)) rupees a day).",
            "Change: \(delta).",
            "Top categories: \(cats.isEmpty ? "none" : cats).",
        ]
        if let m = topMerchant { lines.append("Most-paid party: \(m.name) at \(Int(m.amount)) rupees.") }
        if let b = biggestPurchase { lines.append("Largest single purchase: \(b.name) for \(Int(b.amount)) rupees.") }
        if let peak = peakTrend, trend.count > 1 { lines.append("Busiest stretch: \(peak.label) at \(Int(peak.total)) rupees.") }
        if familySent > 0 { lines.append("Sent to family: \(Int(familySent)) rupees.") }
        if selfTransfers > 0 { lines.append("Moved between own accounts: \(Int(selfTransfers)) rupees.") }
        return lines.joined(separator: "\n")
    }
}

/// Builds `StoryData` from a set of (already member-filtered, income-excluded) expenses.
enum StoryDataBuilder {
    static func build(period: StoryPeriod, expenses: [Transaction],
                      now: Date = Date(), calendar: Calendar = .current) -> StoryData {
        let cal = calendar
        let (current, prior) = period.ranges(now: now, calendar: cal)
        let inPeriod = expenses.filter { current.contains($0.date) }
        let priorTxs = expenses.filter { prior.contains($0.date) }

        let total = inPeriod.reduce(0) { $0 + $1.amount }
        let priorTotal = priorTxs.reduce(0) { $0 + $1.amount }

        // Categories
        let byCat = Dictionary(grouping: inPeriod, by: \.category)
            .map { (cat: $0.key, sum: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.sum > $1.sum }
        let topCategories = byCat.prefix(5).map {
            StoryData.CategorySlice(name: $0.cat.rawValue, icon: $0.cat.icon, total: $0.sum,
                                    percent: total > 0 ? $0.sum / total * 100 : 0)
        }

        // Parties / biggest purchase
        let topMerchant = Dictionary(grouping: inPeriod, by: \.merchant)
            .map { (name: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }
            .max { $0.amount < $1.amount }
            .map { StoryData.NamedAmount(name: $0.name, amount: $0.amount) }
        let biggestPurchase = inPeriod
            .filter { $0.category != .transfer }
            .max { $0.amount < $1.amount }
            .map { StoryData.NamedAmount(name: $0.merchant, amount: $0.amount) }

        // Trend buckets
        let trend = period.isSingleMonth
            ? weeklyTrend(inPeriod, range: current, cal: cal)
            : monthlyTrend(inPeriod, cal: cal)

        let familySent = inPeriod.filter { $0.toFamily == true }.reduce(0) { $0 + $1.amount }
        let selfTransfers = inPeriod.filter { $0.isSelfTransfer == true }.reduce(0) { $0 + $1.amount }

        let dayCount = max(1, (cal.dateComponents([.day], from: current.lowerBound, to: current.upperBound).day ?? 0) + 1)

        return StoryData(period: period, total: total, priorTotal: priorTotal,
                         txCount: inPeriod.count, dayCount: dayCount,
                         topCategories: Array(topCategories), topMerchant: topMerchant,
                         biggestPurchase: biggestPurchase, trend: trend,
                         familySent: familySent, selfTransfers: selfTransfers)
    }

    private static func monthlyTrend(_ txs: [Transaction], cal: Calendar) -> [StoryData.TrendPoint] {
        let groups = Dictionary(grouping: txs) { cal.date(from: cal.dateComponents([.year, .month], from: $0.date)) ?? $0.date }
        let fmt = DateFormatter(); fmt.dateFormat = "MMM"
        return groups.map { StoryData.TrendPoint(date: $0.key, label: fmt.string(from: $0.key),
                                                 total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.date < $1.date }
    }

    private static func weeklyTrend(_ txs: [Transaction], range: Range<Date>, cal: Calendar) -> [StoryData.TrendPoint] {
        let start = range.lowerBound
        func weekIndex(_ d: Date) -> Int { max(0, (cal.dateComponents([.day], from: start, to: d).day ?? 0) / 7) }
        let groups = Dictionary(grouping: txs) { weekIndex($0.date) }
        return groups.map { (wk, items) in
            let date = cal.date(byAdding: .day, value: wk * 7, to: start) ?? start
            return StoryData.TrendPoint(date: date, label: "Wk \(wk + 1)",
                                        total: items.reduce(0) { $0 + $1.amount })
        }.sorted { $0.date < $1.date }
    }
}

// MARK: - Storyboard

/// One screen of the story. The visual is chosen by `kind`; `narration` is both spoken and
/// shown as a caption.
struct StoryScene: Identifiable {
    enum Kind { case title, total, categories, trend, transfers, closing }
    let id = UUID()
    let kind: Kind
    let narration: String
}

/// The assembled story: an ordered set of scenes plus the data they render, and whether the
/// narration came from Apple Intelligence or the built-in fallback.
struct Storyboard {
    let title: String
    let scenes: [StoryScene]
    let data: StoryData
    let isAIGenerated: Bool

    /// Builds the scene list from data + a narration script. Optional scenes (transfers) are
    /// included only when there's data for them.
    static func make(data: StoryData, narration: StoryNarration, isAI: Bool) -> Storyboard {
        var scenes: [StoryScene] = [
            StoryScene(kind: .title, narration: narration.opening),
            StoryScene(kind: .total, narration: narration.total),
            StoryScene(kind: .categories, narration: narration.categories),
        ]
        if data.trend.count > 1 {
            scenes.append(StoryScene(kind: .trend, narration: narration.trend))
        }
        if data.hasTransfers {
            scenes.append(StoryScene(kind: .transfers, narration: narration.transfers))
        }
        scenes.append(StoryScene(kind: .closing, narration: narration.closing))
        return Storyboard(title: narration.title, scenes: scenes, data: data, isAIGenerated: isAI)
    }
}
