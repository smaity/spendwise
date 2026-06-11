// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI
import BackgroundTasks

@main
struct SpendWiseApp: App {
    @StateObject private var store = TransactionStore()
    @StateObject private var appLock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let refreshTaskID = "com.eduquizacademy.spendwise.refresh"

    var body: some Scene {
        WindowGroup {
            ZStack {
                TabView {
                    DashboardView()
                        .tabItem { Label("Dashboard", systemImage: "chart.pie.fill") }
                    TransactionsListView()
                        .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }
                    InsightsView()
                        .tabItem { Label("Insights", systemImage: "lightbulb.fill") }
                    RepeatedSpendsView()
                        .tabItem { Label("Repeats", systemImage: "repeat") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                }
                .environmentObject(store)
                .environmentObject(appLock)

                if appLock.isLocked {
                    LockView().environmentObject(appLock).transition(.opacity)
                }
            }
        }
        // iOS opportunistically wakes the app to fetch new bank-alert emails.
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await store.syncFromGmail(daysBack: 7)   // just the last week — quick, fits the ~30s budget
            Self.scheduleRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                appLock.authenticate()
            case .background:
                appLock.lock()
                Self.scheduleRefresh()
            default:
                break
            }
        }
    }

    /// Asks iOS to run a refresh no sooner than ~4h from now. Actual timing is the OS's call.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
