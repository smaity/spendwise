// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject var store: TransactionStore
    @State private var selectedMonth = Date()

    private var summaries: [CategorySummary] { store.categorySummaries(inMonthOf: selectedMonth) }
    private var monthTotal: Double { store.total(inMonthOf: selectedMonth) }
    private var monthIncome: Double { store.income(inMonthOf: selectedMonth) }
    private var prevMonthTotal: Double {
        let prev = Calendar.current.date(byAdding: .month, value: -1, to: selectedMonth)!
        return store.total(inMonthOf: prev)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if store.memberEmails.count > 1 { memberChips }
                    monthPicker
                    totalCard
                    if !store.visibleTransactions.isEmpty { yearTrend }
                    if store.memberEmails.count > 1 && store.memberFilter == nil {
                        familyBreakdown
                    }
                    if summaries.isEmpty {
                        ContentUnavailableView("No transactions",
                            systemImage: "tray",
                            description: Text("Connect Gmail in Settings or add transactions manually."))
                            .padding(.top, 40)
                    } else {
                        categoryDonut
                        dailyTrend
                        categoryList
                    }
                }
                .padding()
            }
            .navigationTitle("SpendWise")
            .toolbar {
                Button {
                    Task { await store.syncFromGmail() }
                } label: {
                    if store.isSyncing { ProgressView() }
                    else { Image(systemName: "arrow.clockwise") }
                }
            }
            .refreshable { await store.syncFromGmail() }
        }
    }

    // MARK: Components

    /// Family member filter: All / each connected account.
    private var memberChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isOn: store.memberFilter == nil) { store.memberFilter = nil }
                ForEach(store.memberEmails, id: \.self) { email in
                    chip(store.memberLabel(for: email), isOn: store.memberFilter == email) {
                        store.memberFilter = email
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isOn ? .bold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(isOn ? AnyShapeStyle(.teal) : AnyShapeStyle(.quaternary.opacity(0.5)),
                            in: Capsule())
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// Who spent what this month (shown when viewing the whole family).
    private var familyBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By member").font(.headline)
            let members = store.memberTotals(inMonthOf: selectedMonth)
            let maxTotal = members.first?.total ?? 1
            ForEach(members, id: \.email) { m in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(m.label).font(.subheadline.bold())
                        Spacer()
                        Text("₹\(Int(m.total).formatted())")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        Capsule().fill(.teal.gradient)
                            .frame(width: max(8, geo.size.width * m.total / max(maxTotal, 1)))
                    }
                    .frame(height: 8)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { store.memberFilter = m.email }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var monthPicker: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(selectedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDate(selectedMonth, equalTo: Date(), toGranularity: .month))
        }
        .padding(.horizontal, 4)
    }

    private func shiftMonth(_ delta: Int) {
        selectedMonth = Calendar.current.date(byAdding: .month, value: delta, to: selectedMonth)!
    }

    private var totalCard: some View {
        VStack(spacing: 6) {
            Text("Total spent")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("₹\(Int(monthTotal).formatted())")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            if prevMonthTotal > 0 {
                let delta = (monthTotal - prevMonthTotal) / prevMonthTotal * 100
                Label("\(abs(Int(delta)))% \(delta >= 0 ? "more" : "less") than last month",
                      systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(delta >= 0 ? .red : .green)
            }

            if let projected = store.projectedMonthEnd(for: selectedMonth) {
                Label("Projected ~₹\(Int(projected).formatted()) by month-end",
                      systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption).foregroundStyle(.orange)
            }

            if monthIncome > 0 {
                Divider().padding(.vertical, 4)
                HStack {
                    incomeNetItem("Income", value: monthIncome, color: .green)
                    Spacer()
                    let net = monthIncome - monthTotal
                    incomeNetItem(net >= 0 ? "Saved" : "Overspent",
                                  value: abs(net), color: net >= 0 ? .green : .red)
                }
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private func incomeNetItem(_ label: String, value: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text("₹\(Int(value).formatted())")
                .font(.subheadline.bold()).foregroundStyle(color)
        }
    }

    private var categoryDonut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By category").font(.headline)
            Chart(summaries) { s in
                SectorMark(
                    angle: .value("Amount", s.total),
                    innerRadius: .ratio(0.6),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(by: .value("Category", s.category.rawValue))
            }
            .frame(height: 240)
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Last 12 months of spend, ending at the month being viewed, with an ML run-rate
    /// projection drawn as a faint cap on the current month's bar.
    private var yearTrend: some View {
        let data = store.monthlyTotals(lastMonths: 12, endingAt: selectedMonth)
        let avg = data.isEmpty ? 0 : data.reduce(0) { $0 + $1.total } / Double(data.count)
        let projected = store.projectedMonthEnd(for: selectedMonth)
        let cal = Calendar.current
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("12-month trend").font(.headline)
                Spacer()
                if let projected {
                    Text("proj ~₹\(Int(projected).formatted())")
                        .font(.caption).foregroundStyle(.orange)
                } else if avg > 0 {
                    Text("avg ₹\(Int(avg).formatted())/mo")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart {
                // Faint projection drawn first so the solid actual bar sits on top of it.
                if let projected, let current = data.last {
                    BarMark(x: .value("Month", current.month, unit: .month),
                            y: .value("Projected", projected))
                        .foregroundStyle(.orange.opacity(0.3))
                }
                ForEach(data, id: \.month) { item in
                    BarMark(x: .value("Month", item.month, unit: .month),
                            y: .value("Spent", item.total))
                        .foregroundStyle(cal.isDate(item.month, equalTo: selectedMonth, toGranularity: .month)
                                         ? Color.teal : Color.teal.opacity(0.35))
                }
                if avg > 0 {
                    RuleMark(y: .value("Average", avg))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 180)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.narrow))
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var dailyTrend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily spend").font(.headline)
            let daily = store.dailyTotals(inMonthOf: selectedMonth)
            Chart(daily, id: \.day) { item in
                BarMark(
                    x: .value("Day", item.day, unit: .day),
                    y: .value("Spent", item.total)
                )
                .foregroundStyle(.teal.gradient)
            }
            .frame(height: 160)
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            ForEach(summaries) { s in
                NavigationLink {
                    CategoryTransactionsView(category: s.category, month: selectedMonth)
                } label: {
                    HStack {
                        Image(systemName: s.category.icon)
                            .frame(width: 32)
                            .foregroundStyle(.teal)
                        VStack(alignment: .leading) {
                            Text(s.category.rawValue).font(.subheadline.bold())
                            Text("\(s.count) transaction\(s.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("₹\(Int(s.total).formatted())").font(.subheadline.bold())
                            Text("\(Int(s.percentOfSpend))%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                if s.id != summaries.last?.id { Divider() }
            }
        }
        .padding(.horizontal)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Drill-down: the transactions behind a dashboard category for a given month.
struct CategoryTransactionsView: View {
    @EnvironmentObject var store: TransactionStore
    let category: SpendCategory
    let month: Date

    private var txs: [Transaction] {
        store.transactions(inMonthOf: month)
            .filter { $0.category == category }
            .sorted { $0.date > $1.date }
    }
    private var total: Double { txs.reduce(0) { $0 + $1.amount } }

    var body: some View {
        List {
            Section {
                ForEach(txs) { tx in
                    NavigationLink {
                        TransactionDetailView(tx: tx)
                    } label: {
                        TransactionRow(tx: tx)
                    }
                }
            } header: {
                Text("\(txs.count) · ₹\(Int(total).formatted()) in \(month.formatted(.dateTime.month(.wide).year()))")
            }
        }
        .navigationTitle(category.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }
}
