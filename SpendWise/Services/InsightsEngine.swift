// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation

struct Insight: Identifiable {
    enum Kind { case saving, investment, alert }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    let icon: String
    /// Estimated monthly amount involved, if applicable.
    let amount: Double?
}

/// Rule-based insights: where to cut spending + what to do with the savings.
/// NOT financial advice — surfaced as educational suggestions in the UI.
enum InsightsEngine {

    static func insights(for transactions: [Transaction], referenceDate: Date = Date()) -> [Insight] {
        let cal = Calendar.current
        let thisMonth = transactions.filter { cal.isDate($0.date, equalTo: referenceDate, toGranularity: .month) }

        var out: [Insight] = []
        out += anomalyInsights(all: transactions, referenceDate: referenceDate)   // ML: Gaussian anomaly detection
        out += forecastInsight(all: transactions, referenceDate: referenceDate)   // ML: run-rate forecast
        out += foodDeliveryCheck(thisMonth)
        out += subscriptions(transactions)
        out += smallLeaks(thisMonth)
        out += investmentIdeas(thisMonth: thisMonth, allTransactions: transactions)
        return out
    }

    // MARK: ML — anomaly detection

    /// Per-category Gaussian anomaly detection: learns each category's monthly mean/σ from
    /// history and flags this month when it's a statistical outlier. Falls back to a simple
    /// month-over-month spike when there isn't enough history to model a distribution.
    private static func anomalyInsights(all: [Transaction], referenceDate: Date) -> [Insight] {
        let cal = Calendar.current
        guard let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: referenceDate)),
              let lastMonthStart = cal.date(byAdding: .month, value: -1, to: thisMonthStart) else { return [] }

        // category -> (monthStart -> spend)
        var series: [SpendCategory: [Date: Double]] = [:]
        for tx in all {
            guard let m = cal.date(from: cal.dateComponents([.year, .month], from: tx.date)) else { continue }
            series[tx.category, default: [:]][m, default: 0] += tx.amount
        }

        var out: [Insight] = []
        for (cat, byMonth) in series {
            let current = byMonth[thisMonthStart] ?? 0
            guard current > 0 else { continue }
            let history = byMonth.filter { $0.key < thisMonthStart }.map(\.value)

            if history.count >= 3 {
                let mean = history.reduce(0, +) / Double(history.count)
                let variance = history.reduce(0) { $0 + pow($1 - mean, 2) } / Double(history.count)
                let std = variance.squareRoot()
                guard std > 0 else { continue }
                let z = (current - mean) / std
                if z >= 2.0 && current - mean > 500 {
                    out.append(Insight(
                        kind: .alert,
                        title: "Unusual \(cat.rawValue) spending",
                        detail: "₹\(Int(current)) this month is well above your usual ₹\(Int(mean)) (±₹\(Int(std))) — a \(String(format: "%.1f", z))σ jump. Worth a look at what changed.",
                        icon: "exclamationmark.triangle.fill",
                        amount: current - mean
                    ))
                }
            } else if let before = byMonth[lastMonthStart], before > 0,
                      current > before * 1.3, current - before > 500 {
                let pct = Int((current / before - 1) * 100)
                out.append(Insight(
                    kind: .alert,
                    title: "\(cat.rawValue) up \(pct)% this month",
                    detail: "You've spent ₹\(Int(current)) vs ₹\(Int(before)) last month. Worth a look at what changed.",
                    icon: "exclamationmark.triangle.fill",
                    amount: current - before
                ))
            }
        }
        return out.sorted { ($0.amount ?? 0) > ($1.amount ?? 0) }
    }

    // MARK: ML — forecast

    /// Projects month-end spend from the current run-rate and compares it to the historical
    /// monthly average to predict an over/under-budget month.
    private static func forecastInsight(all: [Transaction], referenceDate: Date) -> [Insight] {
        let cal = Calendar.current
        guard let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: referenceDate)),
              let dayRange = cal.range(of: .day, in: .month, for: referenceDate) else { return [] }

        let spentSoFar = all
            .filter { cal.isDate($0.date, equalTo: referenceDate, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
        let dayOfMonth = Double(cal.component(.day, from: referenceDate))
        let daysInMonth = Double(dayRange.count)
        // Need a few days of signal, and skip near month-end where the projection is trivial.
        guard spentSoFar > 0, dayOfMonth >= 3, dayOfMonth < daysInMonth - 1 else { return [] }

        let projected = spentSoFar / dayOfMonth * daysInMonth

        var byMonth: [Date: Double] = [:]
        for tx in all {
            guard let m = cal.date(from: cal.dateComponents([.year, .month], from: tx.date)), m < thisMonthStart else { continue }
            byMonth[m, default: 0] += tx.amount
        }
        let history = Array(byMonth.values)
        guard !history.isEmpty else { return [] }
        let avg = history.reduce(0, +) / Double(history.count)
        guard avg > 0 else { return [] }

        if projected > avg * 1.15 {
            return [Insight(
                kind: .alert,
                title: "On track to overspend this month",
                detail: "At your current pace you'll reach ~₹\(Int(projected)) by month-end, vs your ₹\(Int(avg)) average. Easing off now keeps you on budget.",
                icon: "gauge.with.dots.needle.67percent",
                amount: projected - avg
            )]
        } else {
            return [Insight(
                kind: .saving,
                title: "Projected ~₹\(Int(projected)) this month",
                detail: "You're pacing at or below your ₹\(Int(avg)) monthly average — nicely on track.",
                icon: "gauge.with.dots.needle.33percent",
                amount: nil
            )]
        }
    }

    /// Frequent food delivery → suggest cap.
    private static func foodDeliveryCheck(_ thisMonth: [Transaction]) -> [Insight] {
        let delivery = thisMonth.filter {
            $0.category == .food &&
            ["swiggy", "zomato"].contains(where: $0.merchant.lowercased().contains)
        }
        guard delivery.count >= 6 else { return [] }
        let total = delivery.reduce(0) { $0 + $1.amount }
        let savable = total * 0.4
        return [Insight(
            kind: .saving,
            title: "\(delivery.count) food delivery orders this month",
            detail: "₹\(Int(total)) on Swiggy/Zomato. Cooking or office meals for even half of these could free up ~₹\(Int(savable))/month.",
            icon: "fork.knife.circle.fill",
            amount: savable
        )]
    }

    /// Same merchant + same amount in consecutive months → subscription.
    private static func subscriptions(_ all: [Transaction]) -> [Insight] {
        let cal = Calendar.current
        let byKey = Dictionary(grouping: all) { "\($0.merchant.lowercased())|\($0.amount)" }
        let recurring = byKey.values.filter { txs in
            let months = Set(txs.map { cal.dateComponents([.year, .month], from: $0.date) })
            return months.count >= 2
        }
        guard !recurring.isEmpty else { return [] }
        let monthlyTotal = recurring.reduce(0.0) { $0 + ($1.first?.amount ?? 0) }
        let names = recurring.compactMap { $0.first?.merchant }.prefix(4).joined(separator: ", ")
        return [Insight(
            kind: .saving,
            title: "₹\(Int(monthlyTotal))/month in subscriptions",
            detail: "Recurring charges detected: \(names). Cancel the ones you don't actively use — subscriptions are the easiest spending to reclaim.",
            icon: "repeat.circle.fill",
            amount: monthlyTotal
        )]
    }

    /// Many small transactions add up.
    private static func smallLeaks(_ thisMonth: [Transaction]) -> [Insight] {
        let small = thisMonth.filter { $0.amount < 300 && $0.category != .investment }
        guard small.count >= 10 else { return [] }
        let total = small.reduce(0) { $0 + $1.amount }
        return [Insight(
            kind: .saving,
            title: "\(small.count) small purchases = ₹\(Int(total))",
            detail: "Sub-₹300 spends look harmless individually but totalled ₹\(Int(total)) this month. A weekly UPI budget helps cap these.",
            icon: "drop.fill",
            amount: total * 0.5
        )]
    }

    // MARK: Investment rules (India-focused, educational)

    private static func investmentIdeas(thisMonth: [Transaction], allTransactions: [Transaction]) -> [Insight] {
        var out: [Insight] = []
        let spend = thisMonth.filter { $0.category != .investment }.reduce(0) { $0 + $1.amount }
        let invested = thisMonth.filter { $0.category == .investment }.reduce(0) { $0 + $1.amount }

        // Potential savings pool from the saving insights ≈ 15% of discretionary spend.
        let discretionary = thisMonth
            .filter { [.food, .shopping, .entertainment].contains($0.category) }
            .reduce(0) { $0 + $1.amount }
        let pool = max(500, discretionary * 0.15).rounded(.down)

        if invested == 0 && spend > 0 {
            out.append(Insight(
                kind: .investment,
                title: "No investments detected this month",
                detail: "Even ₹\(Int(pool))/month into a Nifty 50 index fund SIP compounds meaningfully — at ~12% annualised, that's roughly ₹\(Int(pool * 12 * 1.12 * 5)) in 5 years. Apps like Groww, Zerodha Coin or Kuvera make this a 5-minute setup.",
                icon: "chart.line.uptrend.xyaxis.circle.fill",
                amount: pool
            ))
        } else if invested > 0 {
            let rate = invested / max(invested + spend, 1) * 100
            if rate < 20 {
                out.append(Insight(
                    kind: .investment,
                    title: "Investing \(Int(rate))% of outflows",
                    detail: "A common target is 20%+. Topping up your existing SIP by ₹\(Int(pool)) would get you closer without a lifestyle change.",
                    icon: "plus.circle.fill",
                    amount: pool
                ))
            }
        }

        out.append(Insight(
            kind: .investment,
            title: "Parking idle cash",
            detail: "Money sitting in savings (~3% interest) loses to inflation. Options to compare: liquid funds / FDs (~6-7%) for an emergency fund, PPF (7.1%, tax-free, 15-yr lock-in) for safety, ELSS funds for 80C tax saving with equity upside.",
            icon: "indianrupeesign.circle.fill",
            amount: nil
        ))
        return out
    }
}

// MARK: - Repeated-spend analysis

/// A merchant paid more than once, aggregated across time.
struct RepeatedSpend: Identifiable {
    let id = UUID()
    let merchant: String
    let category: SpendCategory
    let count: Int            // number of transactions
    let total: Double         // sum spent at this merchant
    let banks: [String]       // distinct banks/cards used
    let firstSeen: Date
    let lastSeen: Date
    let activeMonths: Int     // distinct calendar months with a charge
    let isSubscription: Bool  // same amount across ≥2 months → likely a fixed subscription

    var average: Double { total / Double(max(count, 1)) }
}

extension InsightsEngine {

    /// Groups transactions by merchant and returns the most-repeated spends, highest
    /// frequency first (ties broken by total spent). One-off merchants are excluded.
    static func repeatedSpends(for transactions: [Transaction], limit: Int = 20) -> [RepeatedSpend] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: transactions) {
            $0.merchant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let spends: [RepeatedSpend] = groups.values.compactMap { txs in
            guard txs.count >= 2 else { return nil }
            let sorted = txs.sorted { $0.date < $1.date }
            let months = Set(txs.map { cal.dateComponents([.year, .month], from: $0.date) })
            // Round to paise to compare amounts safely.
            let distinctAmounts = Set(txs.map { ($0.amount * 100).rounded() })
            return RepeatedSpend(
                merchant: mostCommon(txs.map(\.merchant)) ?? sorted[0].merchant,
                category: mostCommon(txs.map(\.category)) ?? sorted[0].category,
                count: txs.count,
                total: txs.reduce(0) { $0 + $1.amount },
                banks: Array(Set(txs.map(\.bank))).sorted(),
                firstSeen: sorted.first!.date,
                lastSeen: sorted.last!.date,
                activeMonths: months.count,
                isSubscription: distinctAmounts.count == 1 && months.count >= 2
            )
        }

        return Array(spends.sorted { ($0.count, $0.total) > ($1.count, $1.total) }.prefix(limit))
    }

    /// The most frequent element in a list (nil if empty).
    private static func mostCommon<T: Hashable>(_ items: [T]) -> T? {
        items.reduce(into: [T: Int]()) { $0[$1, default: 0] += 1 }
            .max { $0.value < $1.value }?.key
    }
}
