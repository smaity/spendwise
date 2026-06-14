// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: TransactionStore
    @EnvironmentObject var appLock: AppLock
    @State private var connectError: String?
    @State private var renamingAccount: GmailAccount?
    @State private var newLabel = ""
    @State private var historyMonths = 12
    @State private var confirmResync = false
    @State private var confirmSMSResync = false

    var body: some View {
        NavigationStack {
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
                        Text("Sync")
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

                Section {
                    if let name = store.nearbyDeviceName {
                        Label("Synced with \(name)", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label("Looking for your other device on Wi-Fi…", systemImage: "wifi")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Sync with nearby devices now") { store.restartLocalSync() }
                } header: {
                    Text("Nearby sync")
                } footer: {
                    Text("Your iPhone and Mac sync transactions directly over the same Wi-Fi network — no account or server. Keep both apps open on the same network. (Requires the Local Network permission.)")
                }

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

                Section {
                    NavigationLink {
                        RulesView()
                    } label: {
                        Label("Detection rules", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Configure bank senders, category keywords, and named accounts (e.g. society maintenance).")
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

                Section {
                    NavigationLink {
                        ProfileEditorView(profile: store.userProfile)
                    } label: {
                        LabeledContent("Your details",
                                       value: store.userProfile.name.isEmpty ? "Not set" : store.userProfile.name)
                    }
                } header: {
                    Label("You", systemImage: "person.crop.circle")
                } footer: {
                    Text("Your name helps Apple Intelligence personalize insights and tell your own accounts apart from family.")
                }

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
                } header: {
                    Label("Family", systemImage: "person.2.fill")
                } footer: {
                    Text("SpendWise flags transfers you send to these people and totals them in Insights. An account's last 4 digits give an exact match; Apple Intelligence additionally matches by name, nickname, and UPI handle. Runs on-device.")
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
            .confirmationDialog("Clear all synced transactions and re-import the last \(historyMonths) months?",
                                isPresented: $confirmResync, titleVisibility: .visible) {
                Button("Clear & re-sync", role: .destructive) {
                    Task { await store.resyncAll(monthsBack: historyMonths) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Tags and manually-added transactions are kept.")
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
}
