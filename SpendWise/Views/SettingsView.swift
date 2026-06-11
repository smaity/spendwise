import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: TransactionStore
    @EnvironmentObject var appLock: AppLock
    @State private var connectError: String?
    @State private var renamingAccount: GmailAccount?
    @State private var newLabel = ""
    @State private var historyMonths = 12
    @State private var confirmResync = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.gmail.accounts) { account in
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(.teal).font(.title2)
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

                if let err = connectError ?? store.syncError {
                    Section {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
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
                    Text("Review the built-in rules and add your own bank senders and category keywords.")
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
                    LabeledContent("Version", value: "1.1")
                    Text("All data is stored locally on your device. Nothing is uploaded to any server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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
        }
    }
}
