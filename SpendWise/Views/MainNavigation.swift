// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

/// Top-level navigation. iOS uses a bottom TabView; macOS uses a native source-list sidebar
/// (NavigationSplitView), which reads far better in a resizable desktop window than iOS-style
/// tabs stretched across the top.
struct MainNavigation: View {
    enum Tab: String, CaseIterable, Identifiable {
        case dashboard, transactions, balanceSheet, insights, repeats, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dashboard: return "Dashboard"
            case .transactions: return "Transactions"
            case .balanceSheet: return "Balance Sheet"
            case .insights: return "Insights"
            case .repeats: return "Repeats"
            case .settings: return "Settings"
            }
        }
        var icon: String {
            switch self {
            case .dashboard: return "chart.pie.fill"
            case .transactions: return "list.bullet.rectangle"
            case .balanceSheet: return "doc.text.fill"
            case .insights: return "lightbulb.fill"
            case .repeats: return "repeat"
            case .settings: return "gearshape.fill"
            }
        }
        @ViewBuilder var destination: some View {
            switch self {
            case .dashboard: DashboardView()
            case .transactions: TransactionsListView()
            case .balanceSheet: BalanceSheetView()
            case .insights: InsightsView()
            case .repeats: RepeatedSpendsView()
            case .settings: SettingsView()
            }
        }
    }

    #if os(macOS)
    @State private var selection: Tab? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 280)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    BrandLogo(size: 24)
                    Text("SpendWise").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        } detail: {
            (selection ?? .dashboard).destination
                .frame(minWidth: 480)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
    #else
    // Honour a SCREENSHOT_TAB launch env var so each screen can be captured deterministically;
    // defaults to the dashboard for normal launches.
    @State private var selection: Tab = {
        if let raw = ProcessInfo.processInfo.environment["SCREENSHOT_TAB"],
           let tab = Tab(rawValue: raw) { return tab }
        return .dashboard
    }()

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Tab.allCases) { tab in
                tab.destination
                    .tag(tab)
                    .tabItem { Label(tab.title, systemImage: tab.icon) }
            }
        }
    }
    #endif
}
