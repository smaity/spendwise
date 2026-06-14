// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct SpendWiseApp: App {
    @StateObject private var store = TransactionStore()
    @StateObject private var appLock = AppLock()
    @StateObject private var storyLaunch = StoryLaunchRequest.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let refreshTaskID = "com.eduquizacademy.spendwise.refresh"

    @State private var showSplash = true

    #if DEBUG
    /// Debug-only: set the STORY_DEMO launch env var to auto-open the Spending Story player
    /// (handy for screenshotting/UI testing in the Simulator). Compiled out of Release builds.
    @State private var showStoryDemo = ProcessInfo.processInfo.environment["STORY_DEMO"] != nil
    #endif

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainNavigation()
                    .tint(Brand.accent)
                    .environmentObject(store)
                    .environmentObject(appLock)

                if appLock.isLocked {
                    LockView().environmentObject(appLock).transition(.opacity)
                }

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(2)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
            }
            .task {
                // Flag transfers sent to family (Apple Intelligence) for the badges/insight.
                await store.detectFamilyTransfers()
            }
            // "Hey Siri, show my spending story" opens the app and plays it here.
            .fullScreenCover(item: $storyLaunch.period) { period in
                SpendingStoryPlayerView(period: period).environmentObject(store)
            }
            #if DEBUG
            .fullScreenCover(isPresented: $showStoryDemo) {
                SpendingStoryPlayerView(period: .thisMonth).environmentObject(store)
            }
            #endif
        }
        #if os(iOS)
        // iOS opportunistically wakes the app to fetch new bank-alert emails.
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await store.syncFromGmail(daysBack: 7)   // just the last week — quick, fits the ~30s budget
            Self.scheduleRefresh()
        }
        #endif
        #if os(macOS)
        .commands { SpendWiseCommands(store: store) }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                appLock.authenticate()
                store.restartLocalSync()   // re-discover & sync with the other device on launch/resume
                #if os(macOS)
                Task { if store.canReadSMS() { await store.syncFromSMS() } }   // fresh SMS read on focus
                #endif
            case .background:
                appLock.lock()
                #if os(iOS)
                Self.scheduleRefresh()
                #endif
            default:
                break
            }
        }
    }

    #if os(iOS)
    /// Asks iOS to run a refresh no sooner than ~4h from now. Actual timing is the OS's call.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
