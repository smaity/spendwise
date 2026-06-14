// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

/// Top-level settings, organized by category. Each area is its own page so the screen is a short
/// menu rather than one long scroll: data sources & sync, your profile & family, transaction
/// detection & data tools, security, and about.
struct SettingsView: View {
    @EnvironmentObject var store: TransactionStore
    @EnvironmentObject var appLock: AppLock

    private var sourcesSubtitle: String {
        var parts: [String] = []
        let n = store.gmail.accounts.count
        if n > 0 { parts.append("\(n) Gmail") }
        #if os(macOS)
        parts.append("SMS")
        #endif
        if parts.isEmpty { parts.append("Not connected") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        SourcesSettingsView()
                    } label: {
                        settingsRow("Accounts & sync", systemImage: "tray.and.arrow.down.fill",
                                    detail: sourcesSubtitle)
                    }
                    NavigationLink {
                        NearbySyncSettingsView()
                    } label: {
                        settingsRow("Nearby sync", systemImage: "wifi",
                                    detail: store.nearbyDeviceName != nil ? "Connected" : "Searching")
                    }
                } header: {
                    Text("Data sources")
                }

                Section {
                    NavigationLink {
                        ProfileEditorView(profile: store.userProfile)
                    } label: {
                        settingsRow("Your details", systemImage: "person.crop.circle",
                                    detail: store.userProfile.name.isEmpty ? "Not set" : store.userProfile.name)
                    }
                    NavigationLink {
                        FamilyMembersSettingsView()
                    } label: {
                        settingsRow("Family", systemImage: "person.2.fill",
                                    detail: store.familyMembers.isEmpty ? "None" : "\(store.familyMembers.count)")
                    }
                } header: {
                    Text("People")
                }

                Section {
                    NavigationLink {
                        RulesView()
                    } label: {
                        settingsRow("Detection rules", systemImage: "slider.horizontal.3",
                                    detail: "Senders · Categories · Accounts")
                    }
                    NavigationLink {
                        DataToolsSettingsView()
                    } label: {
                        settingsRow("Data & cleanup", systemImage: "wand.and.stars",
                                    detail: "\(store.transactions.count)")
                    }
                } header: {
                    Text("Transactions")
                }

                Section {
                    Toggle(isOn: Binding(get: { appLock.enabled },
                                         set: { appLock.setEnabled($0) })) {
                        Label("Require \(appLock.biometryLabel)", systemImage: appLock.biometryIcon)
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Lock SpendWise behind \(appLock.biometryLabel) each time it opens or returns from the background.")
                }

                Section("About") {
                    HStack(spacing: 12) {
                        BrandLogo(size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Brand.name).font(.headline)
                            Text(Brand.tagline)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Version", value: "1.1")
                    Text("All data is stored locally on your device. Nothing is uploaded to any server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
    }

    private func settingsRow(_ title: String, systemImage: String, detail: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Accounts & sync

/// Connected sources and their sync controls: Gmail accounts + history import, and (on macOS)
/// bank SMS read from Messages.
struct SourcesSettingsView: View {
    @EnvironmentObject var store: TransactionStore
    @State private var connectError: String?
    @State private var renamingAccount: GmailAccount?
    @State private var newLabel = ""
    @State private var historyMonths = 12
    @State private var confirmSMSResync = false

    var body: some View {
        Form {
            Section {
                ForEach(store.gmail.accounts) { account in
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundStyle(Brand.accent).font(.title2)
                        VStack(alignment: .leading) {
                            Text(account.label).font(.subheadline.bold())
                            Text(account.email).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.removeMember(account)
                        } label: { Label("Remove", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button("Rename") {
                            newLabel = account.label
                            renamingAccount = account
                        }
                        Button("Remove account", role: .destructive) {
                            store.removeMember(account)
                        }
                    }
                }

                Button {
                    Task {
                        do {
                            try await store.gmail.connectAccount()
                            await store.syncFromGmail()
                            connectError = nil
                        } catch {
                            connectError = error.localizedDescription
                        }
                    }
                } label: {
                    Label(store.gmail.accounts.isEmpty ? "Connect Gmail" : "Add family member's Gmail",
                          systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Gmail accounts")
            } footer: {
                Text("Connect each family member's Gmail to segregate spending per person. Read-only scope; bank-alert emails only. Long-press an account to rename (e.g. \"Mom\", \"Dad\"). Data never leaves this device.")
            }

            if store.gmail.isConnected {
                Section {
                    if let last = store.lastSync {
                        LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    if store.isSyncing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(store.syncProgress.map { "Fetching \($0)…" } ?? "Syncing…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Sync recent (90 days)") { Task { await store.syncFromGmail() } }
                        Picker("Import history", selection: $historyMonths) {
                            Text("Last 3 months").tag(3)
                            Text("Last 6 months").tag(6)
                            Text("Last 12 months").tag(12)
                        }
                        Button("Import last \(historyMonths) months") {
                            Task { await store.syncFromGmail(monthsBack: historyMonths) }
                        }
                    }
                } header: {
                    Text("Gmail sync")
                } footer: {
                    Text("\"Import history\" fetches bank alerts one month at a time going back up to a year — useful the first time you connect. It may take a minute.")
                }
            }

            #if os(macOS)
            Section {
                if store.syncError == TransactionStore.fullDiskAccessSentinel {
                    GrantFullDiskAccessView { Task { await store.syncFromSMS() } }
                } else {
                    if store.isSyncing {
                        HStack(spacing: 8) { ProgressView(); Text("Reading Messages…").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Button("Sync bank SMS from Messages") {
                            Task { await store.syncFromSMS() }
                        }
                        Button(role: .destructive) {
                            confirmSMSResync = true
                        } label: {
                            Label("Clear & re-sync all SMS", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    if let status = store.smsStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Messages (SMS)")
            } footer: {
                Text("Reads bank transaction SMS forwarded to this Mac from your iPhone (Text Message Forwarding). Captures UPI and small-value payments that don't arrive by email. Read on-device only.")
            }
            #endif

            if let err = connectError ?? store.syncError,
               err != TransactionStore.fullDiskAccessSentinel {
                Section {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts & Sync")
        .alert("Rename account", isPresented: Binding(
            get: { renamingAccount != nil },
            set: { if !$0 { renamingAccount = nil } }
        )) {
            TextField("Name", text: $newLabel)
            Button("Save") {
                if let account = renamingAccount {
                    store.gmail.rename(account, to: newLabel)
                }
                renamingAccount = nil
            }
            Button("Cancel", role: .cancel) { renamingAccount = nil }
        } message: {
            Text("Shown on the dashboard, e.g. \"Mom\" or \"Dad\".")
        }
        #if os(macOS)
        .confirmationDialog("Clear all SMS-imported transactions and re-read them from Messages?",
                            isPresented: $confirmSMSResync, titleVisibility: .visible) {
            Button("Clear & re-sync SMS", role: .destructive) {
                Task { await store.clearAndResyncSMS() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Gmail rows, tags, and manual transactions are kept.")
        }
        #endif
    }
}

// MARK: - Nearby sync

struct NearbySyncSettingsView: View {
    @EnvironmentObject var store: TransactionStore

    var body: some View {
        Form {
            Section {
                if let name = store.nearbyDeviceName {
                    Label("Synced with \(name)", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.green)
                } else {
                    Label("Looking for your other device on Wi-Fi…", systemImage: "wifi")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Sync with nearby devices now") { store.restartLocalSync() }
            } footer: {
                Text("Your iPhone and Mac sync transactions directly over the same Wi-Fi network — no account or server. Keep both apps open on the same network. (Requires the Local Network permission.)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Nearby Sync")
    }
}

// MARK: - Family

struct FamilyMembersSettingsView: View {
    @EnvironmentObject var store: TransactionStore

    var body: some View {
        Form {
            Section {
                ForEach(store.familyMembers) { member in
                    NavigationLink {
                        FamilyMemberEditorView(member: member, isNew: false)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name).font(.subheadline.bold())
                            let detail = [member.relationship.isEmpty ? nil : member.relationship,
                                          member.accountLast4Digits.map { "•• \($0)" }]
                                .compactMap { $0 }.joined(separator: " · ")
                            if !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.removeFamilyMember(member) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                NavigationLink {
                    FamilyMemberEditorView(member: FamilyMember(name: ""), isNew: true)
                } label: {
                    Label("Add family member", systemImage: "plus")
                }
            } footer: {
                Text("SpendWise flags transfers you send to these people and totals them in Insights. An account's last 4 digits give an exact match; Apple Intelligence additionally matches by name, nickname, and UPI handle. Runs on-device.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Family")
    }
}

// MARK: - Data & cleanup

struct DataToolsSettingsView: View {
    @EnvironmentObject var store: TransactionStore
    @State private var historyMonths = 12
    @State private var confirmResync = false

    var body: some View {
        Form {
            Section {
                Button("Find duplicates with Apple Intelligence") {
                    Task { await store.collapseDuplicatesWithAI() }
                }
                .disabled(store.isSyncing)
                if let status = store.dedupStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }

                Button("Remove non-transactions with Apple Intelligence") {
                    Task { await store.removeNonTransactionsWithAI() }
                }
                .disabled(store.isSyncing)
                if let status = store.validationStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Clean up with Apple Intelligence")
            } footer: {
                Text("Duplicates (same payment reported by email and SMS) are merged. Non-transactions — bill reminders, scheduled/upcoming auto-debits, payment requests, and declined attempts — are detected and removed, while genuine debits are kept. Exact duplicates and obvious reminders are already filtered automatically on every sync.")
            }

            Section {
                LabeledContent("Transactions", value: "\(store.transactions.count)")
                Button("Remove sample data", role: .destructive) {
                    store.transactions.removeAll { $0.source == "sample" }
                    store.save()
                }
                .disabled(!store.transactions.contains { $0.source == "sample" })

                Button(role: .destructive) {
                    confirmResync = true
                } label: {
                    Label("Clear & re-sync \(historyMonths) months", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isSyncing || !store.gmail.isConnected)
            } header: {
                Text("Data")
            } footer: {
                Text("Clearing rebuilds transactions from Gmail. Your tags and manually-added transactions are kept.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Data & Cleanup")
        .confirmationDialog("Clear all synced transactions and re-import the last \(historyMonths) months?",
                            isPresented: $confirmResync, titleVisibility: .visible) {
            Button("Clear & re-sync", role: .destructive) {
                Task { await store.resyncAll(monthsBack: historyMonths) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Tags and manually-added transactions are kept.")
        }
    }
}
