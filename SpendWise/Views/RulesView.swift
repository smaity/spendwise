// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

/// In-app editor for transaction-detection rules: which bank senders to fetch and how
/// merchants map to categories. Built-in rules are shown for review; custom rules are
/// editable and take precedence.
struct RulesView: View {
    @ObservedObject private var rules = RulesStore.shared

    @State private var newSender = ""
    @State private var newKeyword = ""
    @State private var newCategory: SpendCategory = .other

    var body: some View {
        List {
            // MARK: Custom senders
            Section {
                ForEach(rules.customSenders, id: \.self) { sender in
                    Label(sender, systemImage: "envelope").font(.subheadline)
                }
                .onDelete(perform: rules.removeSenders)

                HStack {
                    TextField("add bank sender e.g. alerts@bank.com", text: $newSender)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    Button("Add") { rules.addSender(newSender); newSender = "" }
                        .disabled(!newSender.contains("@"))
                }
            } header: {
                Text("Bank senders")
            } footer: {
                Text("Emails fetched from Gmail. Add a sender if a bank's alerts aren't being picked up.")
            }

            // MARK: Built-in senders (read-only)
            Section {
                DisclosureGroup("Built-in senders (\(GmailService.builtinSenders.count))") {
                    ForEach(GmailService.builtinSenders, id: \.self) { sender in
                        Text(sender).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: Custom category rules
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
                Text("Category rules")
            } footer: {
                Text("If a transaction's merchant or text contains the keyword, it's filed under your category. These override the built-in rules.")
            }

            // MARK: Built-in category rules (read-only)
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
        .navigationTitle("Detection Rules")
        .toolbar { EditButton() }
    }
}
