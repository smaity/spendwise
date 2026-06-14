// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

/// Top-level configuration menu for transaction-detection rules. Each area is its own
/// configurable page: which bank senders to fetch, how merchants map to categories, and
/// names for recipient accounts. Built-in rules are shown for review; custom rules are
/// editable and take precedence.
struct RulesView: View {
    @ObservedObject private var rules = RulesStore.shared

    var body: some View {
        List {
            NavigationLink {
                BankSendersView()
            } label: {
                ruleRow("Bank senders", systemImage: "envelope",
                        detail: "\(rules.customSenders.count) custom · \(GmailService.builtinSenders.count) built-in")
            }
            NavigationLink {
                CategoryRulesView()
            } label: {
                ruleRow("Category rules", systemImage: "text.magnifyingglass",
                        detail: "\(rules.customCategoryRules.count) custom")
            }
            NavigationLink {
                NamedAccountsView()
            } label: {
                ruleRow("Named accounts", systemImage: "person.text.rectangle",
                        detail: rules.payeeAccountRules.isEmpty ? "none yet"
                            : "\(rules.payeeAccountRules.count) named")
            }
        }
        .navigationTitle("Detection Rules")
    }

    private func ruleRow(_ title: String, systemImage: String, detail: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Bank senders

/// Which email senders' bank alerts are fetched from Gmail.
struct BankSendersView: View {
    @ObservedObject private var rules = RulesStore.shared
    @State private var newSender = ""

    var body: some View {
        List {
            Section {
                ForEach(rules.customSenders, id: \.self) { sender in
                    Label(sender, systemImage: "envelope").font(.subheadline)
                }
                .onDelete(perform: rules.removeSenders)

                HStack {
                    TextField("add bank sender e.g. alerts@bank.com", text: $newSender)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        #endif
                    Button("Add") { rules.addSender(newSender); newSender = "" }
                        .disabled(!newSender.contains("@"))
                }
            } header: {
                Text("Your senders")
            } footer: {
                Text("Emails fetched from Gmail. Add a sender if a bank's alerts aren't being picked up.")
            }

            Section {
                DisclosureGroup("Built-in senders (\(GmailService.builtinSenders.count))") {
                    ForEach(GmailService.builtinSenders, id: \.self) { sender in
                        Text(sender).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Bank Senders")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }
}

// MARK: - Category rules

/// Keyword → category overrides, layered on top of the built-in rules.
struct CategoryRulesView: View {
    @ObservedObject private var rules = RulesStore.shared
    @State private var newKeyword = ""
    @State private var newCategory: SpendCategory = .other

    var body: some View {
        List {
            Section {
                ForEach(rules.customCategoryRules) { rule in
                    HStack {
                        Label(rule.keyword, systemImage: "text.magnifyingglass")
                        Spacer()
                        Text(rule.category.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: rules.removeCategoryRules)

                VStack(spacing: 8) {
                    TextField("keyword e.g. freshmenu", text: $newKeyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Picker("Category", selection: $newCategory) {
                            ForEach(SpendCategory.allCases) { cat in
                                Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                            }
                        }
                        Spacer()
                        Button("Add") {
                            rules.addCategoryRule(keyword: newKeyword, category: newCategory)
                            newKeyword = ""
                        }
                        .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("Your rules")
            } footer: {
                Text("If a transaction's merchant or text contains the keyword, it's filed under your category. These override the built-in rules.")
            }

            Section {
                DisclosureGroup("Built-in category rules") {
                    ForEach(TransactionParser.categorySeeds, id: \.category) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.category.rawValue).font(.caption.bold())
                            Text(rule.keywords.joined(separator: ", "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                Text("Rule changes apply to newly-synced transactions. To re-apply to your history, use Clear & re-sync.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Category Rules")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }
}

// MARK: - Named accounts (payee rules)

/// Names recipient accounts the bank reports only by number (society maintenance, rent, a
/// recurring payee) so they read clearly and get the right category. Rows are tap-to-edit;
/// changes apply across existing history immediately.
struct NamedAccountsView: View {
    @EnvironmentObject private var store: TransactionStore
    @ObservedObject private var rules = RulesStore.shared

    @State private var newPayeeAccount = ""
    @State private var newPayeeName = ""
    @State private var newPayeeCategory: SpendCategory = .utilities
    @State private var editingPayee: PayeeRef?

    var body: some View {
        List {
            Section {
                if rules.payeeAccountRules.isEmpty {
                    Text("No named accounts yet. Add one below, or use “Name account…” from any transfer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rules.payeeAccountRules) { rule in
                    Button {
                        editingPayee = PayeeRef(accountLast4: rule.accountLast4, defaultName: rule.payee)
                    } label: {
                        HStack {
                            Label(rule.payee, systemImage: "person.text.rectangle")
                            Spacer()
                            Text("••\(rule.accountLast4) · \(rule.category.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: rules.removePayeeRules)
            } header: {
                Text("Your named accounts")
            } footer: {
                Text("Tap to edit. Every transfer to that account — past and future — gets this name and category, and won't count as a family transfer.")
            }

            Section("Add new") {
                HStack {
                    TextField("account last 4 e.g. 1234", text: $newPayeeAccount)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("payee e.g. Society Maintenance", text: $newPayeeName)
                }
                Picker("Category", selection: $newPayeeCategory) {
                    ForEach(SpendCategory.allCases) { cat in
                        Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                    }
                }
                Button("Add named account") {
                    let last4 = String(newPayeeAccount.filter(\.isNumber).suffix(4))
                    rules.setPayeeRule(accountLast4: last4, payee: newPayeeName, category: newPayeeCategory)
                    store.applyPayeeRule(accountLast4: last4)   // relabel history now
                    newPayeeAccount = ""; newPayeeName = ""
                }
                .disabled(newPayeeAccount.filter(\.isNumber).count < 4
                          || newPayeeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Named Accounts")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
        .sheet(item: $editingPayee) { ref in
            NamePayeeView(accountLast4: ref.accountLast4, defaultName: ref.defaultName)
        }
    }
}
