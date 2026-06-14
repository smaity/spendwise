// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject var store: TransactionStore

    // Respects the family-member filter set on the Dashboard. Spends only (income excluded).
    private var insights: [Insight] { InsightsEngine.insights(for: store.visibleExpenses) }
    private var savings: [Insight] { insights.filter { $0.kind == .saving || $0.kind == .alert } }
    private var investments: [Insight] { insights.filter { $0.kind == .investment } }
    private var potentialMonthlySaving: Double {
        savings.compactMap(\.amount).reduce(0, +)
    }

    // Apple Intelligence summary (iOS 26+). Section stays hidden when AI is unavailable.
    private let ai = AIInsightsService()
    @State private var aiInsight: SpendingInsight?
    @State private var aiState: AIState = .idle
    private enum AIState { case idle, loading, done, hidden }
    @State private var showAsk = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let filter = store.memberFilter {
                        Label("Showing \(store.memberLabel(for: filter))'s spending",
                              systemImage: "person.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if potentialMonthlySaving > 0 { headline }

                    SpendingStoryCard()

                    aiSection
                    familyTransfersCard

                    if !savings.isEmpty {
                        section("Cut spending", items: savings)
                    }
                    if !investments.isEmpty {
                        section("Put savings to work", items: investments)
                    }
                    if insights.isEmpty {
                        ContentUnavailableView {
                            Image(systemName: "lightbulb.fill").font(.largeTitle).foregroundStyle(Brand.accent)
                            Text("Insights are warming up").font(.headline).padding(.top, 4)
                        } description: {
                            Text("Once you have a month or two of transactions, SpendWise surfaces savings, trends, and spend spikes here.")
                        }
                        .padding(.top, 60)
                    }

                    Text("Educational suggestions only — not financial advice. Consider a SEBI-registered advisor for personalised guidance.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Insights")
            .task(id: store.memberFilter) { await loadAIInsight() }
            .task { await store.detectFamilyTransfers() }
            .sheet(isPresented: $showAsk) {
                AskAIView().environmentObject(store)
            }
        }
    }

    // MARK: - Apple Intelligence section

    @ViewBuilder private var aiSection: some View {
        switch aiState {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Analyzing your spending with Apple Intelligence…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Brand.ai.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        case .done:
            VStack(spacing: 12) {
                if let aiInsight { AIInsightCard(insight: aiInsight) }
                askButton
            }
        case .idle, .hidden:
            EmptyView()
        }
    }

    /// Money sent to family this month, detected by Apple Intelligence. Hidden when none.
    @ViewBuilder private var familyTransfersCard: some View {
        let fam = store.familyTransfers()
        if !fam.isEmpty {
            let total = fam.reduce(0) { $0 + $1.amount }
            let byMember = Dictionary(grouping: fam, by: { $0.familyMember ?? "Family" })
                .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
                .sorted { $0.total > $1.total }
            VStack(alignment: .leading, spacing: 10) {
                Label("Sent to family this month", systemImage: "person.2.fill")
                    .font(.caption.bold()).foregroundStyle(.pink)
                Text("₹\(Int(total).formatted())")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                ForEach(byMember, id: \.name) { m in
                    HStack {
                        Text(m.name)
                        Spacer()
                        Text("₹\(Int(m.total).formatted())").bold()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Label("Detected with Apple Intelligence", systemImage: "sparkles")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var askButton: some View {
        Button { showAsk = true } label: {
            Label("Ask about your spending", systemImage: "sparkles")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Brand.ai.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(Brand.ai)
        }
        .buttonStyle(.plain)
    }

    /// Generates the AI summary once Apple Intelligence is confirmed available and there's
    /// data to summarize. Re-runs when the member filter changes.
    @MainActor private func loadAIInsight() async {
        let expenses = store.visibleExpenses
        guard ai.isAvailable(), !expenses.isEmpty else { aiState = .hidden; return }
        aiState = .loading
        let result = await ai.generate(spendingSummary: Self.spendingSummary(for: expenses))
        aiInsight = result
        aiState = result == nil ? .hidden : .done
    }

    /// A compact, model-friendly digest of spending: this month's total, the prior month,
    /// per-category totals, and the top merchants.
    static func spendingSummary(for txs: [Transaction], referenceDate: Date = Date()) -> String {
        let cal = Calendar.current
        let thisMonth = txs.filter { cal.isDate($0.date, equalTo: referenceDate, toGranularity: .month) }
        let total = thisMonth.reduce(0) { $0 + $1.amount }

        var lastTotal = 0.0
        if let thisStart = cal.date(from: cal.dateComponents([.year, .month], from: referenceDate)),
           let lastStart = cal.date(byAdding: .month, value: -1, to: thisStart) {
            lastTotal = txs.filter { cal.isDate($0.date, equalTo: lastStart, toGranularity: .month) }
                           .reduce(0) { $0 + $1.amount }
        }

        let byCat = Dictionary(grouping: thisMonth, by: \.category)
            .mapValues { $0.reduce(0) { $0 + $1.amount } }
            .sorted { $0.value > $1.value }
        let byMerchant = Dictionary(grouping: thisMonth, by: \.merchant)
            .mapValues { $0.reduce(0) { $0 + $1.amount } }
            .sorted { $0.value > $1.value }
            .prefix(5)

        let cats = byCat.map { "\($0.key.rawValue) ₹\(Int($0.value))" }.joined(separator: ", ")
        let merchants = byMerchant.map { "\($0.key) ₹\(Int($0.value))" }.joined(separator: ", ")
        return """
        This month total spend: ₹\(Int(total)). Last month: ₹\(Int(lastTotal)).
        Spend by category: \(cats.isEmpty ? "none" : cats).
        Top merchants: \(merchants.isEmpty ? "none" : merchants).
        """
    }

    private var headline: some View {
        VStack(spacing: 4) {
            Text("Potential monthly savings")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("₹\(Int(potentialMonthlySaving).formatted())")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func section(_ title: String, items: [Insight]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(items) { insight in
                InsightCard(insight: insight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Card for the Apple Intelligence-generated summary + tips.
struct AIInsightCard: View {
    let insight: SpendingInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Apple Intelligence", systemImage: "sparkles")
                .font(.caption.bold())
                .foregroundStyle(Brand.ai)

            Text(insight.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if !insight.tips.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(insight.tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                            Text(tip)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            LinearGradient(colors: [Brand.ai.opacity(0.12), .blue.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }
}

struct InsightCard: View {
    let insight: Insight

    private var tint: Color {
        switch insight.kind {
        case .alert: return .orange
        case .saving: return Brand.accent
        case .investment: return .green
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.icon)
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.15), in: Circle())
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title).font(.subheadline.bold())
                Text(insight.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Top repeated spends

struct RepeatedSpendsView: View {
    @EnvironmentObject var store: TransactionStore

    private var spends: [RepeatedSpend] {
        InsightsEngine.repeatedSpends(for: store.visibleExpenses, limit: 20)
    }

    var body: some View {
        NavigationStack {
            List {
                if store.memberEmails.count > 1 {
                    Section {
                        let scope = store.memberFilter.map { "\(store.memberLabel(for: $0))'s repeats" } ?? "Whole family"
                        Label("Showing \(scope)",
                              systemImage: store.memberFilter == nil ? "person.2.fill" : "person.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !store.allTags.isEmpty {
                    Section("Tags") {
                        ForEach(store.allTags, id: \.self) { tag in
                            NavigationLink {
                                TagDetailView(tag: tag)
                            } label: {
                                Label(tag, systemImage: "tag.fill").foregroundStyle(Brand.ai)
                            }
                        }
                    }
                }

                if spends.isEmpty {
                    ContentUnavailableView {
                        Image(systemName: "repeat").font(.largeTitle).foregroundStyle(Brand.accent)
                        Text("No repeated spends yet").font(.headline).padding(.top, 4)
                    } description: {
                        Text("Merchants you pay more than once will rank here. Import more history from Settings → Sync.")
                    }
                } else {
                    Section {
                        ForEach(Array(spends.enumerated()), id: \.element.id) { index, spend in
                            NavigationLink {
                                PartyDetailView(merchant: spend.merchant)
                            } label: {
                                RepeatedSpendRow(rank: index + 1, spend: spend)
                            }
                        }
                    } footer: {
                        Text("Tap a party to see its spend over time and tag it. \"Subscription\" marks a fixed amount charged across 2+ months.")
                    }
                }
            }
            .navigationTitle("Top Repeats")
            .toolbar {
                if store.memberEmails.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Whole family") { store.memberFilter = nil }
                            ForEach(store.memberEmails, id: \.self) { email in
                                Button(store.memberLabel(for: email)) { store.memberFilter = email }
                            }
                        } label: {
                            Image(systemName: "person.2")
                        }
                    }
                }
            }
        }
    }
}

struct RepeatedSpendRow: View {
    let rank: Int
    let spend: RepeatedSpend

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.bold().monospacedDigit())
                .frame(width: 24)
                .foregroundStyle(.secondary)

            Image(systemName: spend.category.icon)
                .frame(width: 38, height: 38)
                .background(Brand.accent.opacity(0.15), in: Circle())
                .foregroundStyle(Brand.accent)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spend.merchant).font(.subheadline.bold())
                    if spend.isSubscription {
                        Text("SUBSCRIPTION")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Brand.ai.opacity(0.15), in: Capsule())
                            .foregroundStyle(Brand.ai)
                    }
                }
                Text("\(spend.category.rawValue) · \(spend.banks.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("avg \(money(spend.average)) · across \(spend.activeMonths) month\(spend.activeMonths == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(money(spend.total)).font(.subheadline.bold())
                Text("\(spend.count)×")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Brand.accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(Brand.accent)
            }
        }
        .padding(.vertical, 2)
    }

    private func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "INR"
        f.currencySymbol = "₹"
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "₹\(Int(v))"
    }
}

// MARK: - Drill-down: a single party (merchant) over time, with tagging

/// Lightweight Identifiable wrapper so a merchant string can drive a `.sheet(item:)`.
struct PartyRef: Identifiable { let id = UUID(); let merchant: String }

struct PartyDetailView: View {
    @EnvironmentObject var store: TransactionStore
    let merchant: String
    @State private var newTag = ""

    private var txs: [Transaction] { store.transactions(forMerchant: merchant) }
    private var monthly: [(month: Date, total: Double)] { store.monthlySpend(of: txs) }
    private var total: Double { txs.reduce(0) { $0 + $1.amount } }
    private var tags: [String] { store.tags(forMerchant: merchant) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text("₹\(Int(total).formatted())")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("\(txs.count) transaction\(txs.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }

            Section("Spend over time") {
                if monthly.isEmpty {
                    Text("No transactions yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Chart(monthly, id: \.month) { item in
                        BarMark(x: .value("Month", item.month, unit: .month),
                                y: .value("Spent", item.total))
                            .foregroundStyle(Brand.accent.gradient)
                    }
                    .frame(height: 180)
                }
            }

            Section("Tags") {
                ForEach(tags, id: \.self) { tag in
                    HStack {
                        Label(tag, systemImage: "tag.fill").foregroundStyle(Brand.ai)
                        Spacer()
                        Button(role: .destructive) {
                            store.removeTag(tag, fromMerchant: merchant)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("New tag (e.g. Rent, Kids, Office)", text: $newTag)
                    Button("Add") {
                        store.addTag(newTag, toMerchant: merchant); newTag = ""
                    }
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                let suggestions = store.allTags.filter { s in
                    !tags.contains { $0.caseInsensitiveCompare(s) == .orderedSame }
                }
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { s in
                                Button { store.addTag(s, toMerchant: merchant) } label: {
                                    Text("+ \(s)").font(.caption)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Brand.ai.opacity(0.12), in: Capsule())
                                        .foregroundStyle(Brand.ai)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Section("Transactions") {
                ForEach(txs.sorted { $0.date > $1.date }) { tx in
                    NavigationLink {
                        TransactionDetailView(tx: tx)
                    } label: {
                        TransactionRow(tx: tx)
                    }
                }
            }
        }
        .navigationTitle(merchant)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Drill-down: everything under one tag over time

struct TagDetailView: View {
    @EnvironmentObject var store: TransactionStore
    let tag: String

    private var txs: [Transaction] { store.transactions(taggedWith: tag) }
    private var monthly: [(month: Date, total: Double)] { store.monthlySpend(of: txs) }
    private var total: Double { txs.reduce(0) { $0 + $1.amount } }
    private var parties: [(merchant: String, total: Double, count: Int)] {
        Dictionary(grouping: txs, by: \.merchant)
            .map { (merchant: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }, count: $0.value.count) }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text("₹\(Int(total).formatted())")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("\(txs.count) transactions · \(parties.count) part\(parties.count == 1 ? "y" : "ies")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }

            Section("Spend over time") {
                if monthly.isEmpty {
                    Text("No transactions under this tag yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Chart(monthly, id: \.month) { item in
                        BarMark(x: .value("Month", item.month, unit: .month),
                                y: .value("Spent", item.total))
                            .foregroundStyle(Brand.ai.gradient)
                    }
                    .frame(height: 180)
                }
            }

            Section("Parties") {
                ForEach(parties, id: \.merchant) { p in
                    NavigationLink {
                        PartyDetailView(merchant: p.merchant)
                    } label: {
                        HStack {
                            Text(p.merchant).font(.subheadline.bold())
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("₹\(Int(p.total).formatted())").font(.subheadline.bold())
                                Text("\(p.count)×").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(tag)
        .navigationBarTitleDisplayMode(.inline)
    }
}
