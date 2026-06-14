// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

/// A simple income & expenditure statement (receipts and payments) in the format accountants
/// recognise: income at the top, expenditure by category, and the net surplus or deficit —
/// built entirely from the parsed bank messages.
struct BalanceSheetView: View {
    @EnvironmentObject var store: TransactionStore

    enum Period: String, CaseIterable, Identifiable { case month = "Month", year = "Year", all = "All time"; var id: String { rawValue } }
    @State private var period: Period = .month
    @State private var anchor = Date()

    private var interval: DateInterval? {
        switch period {
        case .month: return Calendar.current.dateInterval(of: .month, for: anchor)
        case .year:  return Calendar.current.dateInterval(of: .year, for: anchor)
        case .all:   return nil
        }
    }
    private var s: FinancialStatement { store.financialStatement(in: interval) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    periodControls
                    section("Income", lines: s.incomeLines, total: s.income, totalColor: .green, isIncome: true)
                    section("Expenditure", lines: s.expenditureLines, total: s.expenditure, totalColor: .primary, isIncome: false)
                    netRow
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Balance Sheet")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Income & Expenditure Statement").font(.headline)
            Text(periodLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var periodControls: some View {
        Picker("Period", selection: $period) {
            ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)

        if period != .all {
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(periodLabel).font(.subheadline.bold())
                Spacer()
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isCurrentPeriod)
            }
            .buttonStyle(.bordered)
        }
    }

    private var periodLabel: String {
        switch period {
        case .month: return anchor.formatted(.dateTime.month(.wide).year())
        case .year:  return anchor.formatted(.dateTime.year())
        case .all:
            if let p = s.period {
                return "\(p.lowerBound.formatted(date: .abbreviated, time: .omitted)) – \(p.upperBound.formatted(date: .abbreviated, time: .omitted))"
            }
            return "All time"
        }
    }

    private var isCurrentPeriod: Bool {
        let cal = Calendar.current
        switch period {
        case .month: return cal.isDate(anchor, equalTo: Date(), toGranularity: .month)
        case .year:  return cal.isDate(anchor, equalTo: Date(), toGranularity: .year)
        case .all:   return true
        }
    }

    private func step(_ dir: Int) {
        let comp: Calendar.Component = period == .year ? .year : .month
        if let d = Calendar.current.date(byAdding: comp, value: dir, to: anchor) { anchor = d }
    }

    private func section(_ title: String, lines: [StatementLine], total: Double, totalColor: Color, isIncome: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 6)

            ForEach(lines) { line in
                NavigationLink {
                    StatementLineDetailView(line: line, isIncome: isIncome, interval: interval)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: line.icon).font(.caption).frame(width: 22).foregroundStyle(.secondary)
                        Text(line.name).font(.subheadline)
                        Spacer()
                        Text(money(line.amount)).font(.subheadline.monospacedDigit())
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }

            HStack {
                Text("Total \(title)").font(.subheadline.bold())
                Spacer()
                Text(money(total)).font(.subheadline.bold().monospacedDigit()).foregroundStyle(totalColor)
            }
            .padding(.top, 8)
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var netRow: some View {
        let surplus = s.net >= 0
        return HStack {
            Text(surplus ? "Surplus (Income − Expenditure)" : "Deficit (Income − Expenditure)")
                .font(.subheadline.bold())
            Spacer()
            Text(money(abs(s.net)))
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(surplus ? .green : .red)
        }
        .padding()
        .background((surplus ? Color.green : .red).opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func money(_ v: Double) -> String { "₹\(Int(v).formatted())" }
}

/// The transactions that make up one Balance Sheet line (a category or income source) in the
/// selected period — reached by tapping a line on the statement.
struct StatementLineDetailView: View {
    @EnvironmentObject var store: TransactionStore
    let line: StatementLine
    let isIncome: Bool
    let interval: DateInterval?

    private var rows: [Transaction] { store.transactions(forStatementLine: line.name, isIncome: isIncome, in: interval) }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("\(rows.count) transaction\(rows.count == 1 ? "" : "s")")
                    Spacer()
                    Text("₹\(Int(line.amount).formatted())").bold()
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                ForEach(rows) { tx in
                    NavigationLink { TransactionDetailView(tx: tx) } label: { TransactionRow(tx: tx) }
                }
            }
        }
        .navigationTitle(line.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
