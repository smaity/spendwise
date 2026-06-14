// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

struct TransactionsListView: View {
    @EnvironmentObject var store: TransactionStore
    @State private var search = ""
    @State private var filterCategory: SpendCategory?
    @State private var ownAccountOnly = false
    @State private var showAdd = false
    @State private var taggingParty: PartyRef?
    @State private var namingPayee: PayeeRef?

    private var filtered: [Transaction] {
        store.visibleTransactions.filter { tx in
            (filterCategory == nil || tx.category == filterCategory) &&
            (!ownAccountOnly || tx.isSelfTransfer == true) &&
            (search.isEmpty || tx.merchant.localizedCaseInsensitiveContains(search))
        }
    }

    private var hasSelfTransfers: Bool { store.visibleTransactions.contains { $0.isSelfTransfer == true } }

    private var showMemberBadge: Bool { store.memberEmails.count > 1 && store.memberFilter == nil }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { tx in
                    NavigationLink {
                        TransactionDetailView(tx: tx)
                    } label: {
                        TransactionRow(tx: tx,
                                       memberLabel: showMemberBadge ? store.memberLabel(for: tx.account) : nil)
                    }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.delete(tx) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Menu("Change category") {
                                ForEach(SpendCategory.allCases) { cat in
                                    Button(cat.rawValue) { store.recategorize(tx, to: cat) }
                                }
                            }
                            Button {
                                taggingParty = PartyRef(merchant: tx.merchant)
                            } label: {
                                Label("Tag party…", systemImage: "tag")
                            }
                            if let last4 = tx.recipientAccountLast4 {
                                Button {
                                    namingPayee = PayeeRef(accountLast4: last4, defaultName: tx.merchant)
                                } label: {
                                    Label("Name account ••\(last4)…", systemImage: "person.text.rectangle")
                                }
                            }
                        }
                }
            }
            .searchable(text: $search, prompt: "Search merchant")
            .navigationTitle("Transactions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if store.memberEmails.count > 1 {
                            Section("Member") {
                                Button("Whole family") { store.memberFilter = nil }
                                ForEach(store.memberEmails, id: \.self) { email in
                                    Button(store.memberLabel(for: email)) { store.memberFilter = email }
                                }
                            }
                        }
                        Section("Category") {
                            Button("All categories") { filterCategory = nil }
                            ForEach(SpendCategory.allCases) { cat in
                                Button(cat.rawValue) { filterCategory = cat }
                            }
                        }
                        if hasSelfTransfers {
                            Section("Transfers") {
                                Toggle("Own-account only", isOn: $ownAccountOnly)
                            }
                        }
                    } label: {
                        Image(systemName: (filterCategory == nil && !ownAccountOnly)
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddTransactionView() }
            .sheet(item: $taggingParty) { ref in
                NavigationStack {
                    PartyDetailView(merchant: ref.merchant)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { taggingParty = nil }
                            }
                        }
                }
            }
            .sheet(item: $namingPayee) { ref in
                NamePayeeView(accountLast4: ref.accountLast4, defaultName: ref.defaultName)
            }
        }
    }
}

struct TransactionRow: View {
    let tx: Transaction
    var memberLabel: String? = nil

    /// Whether a date carries a real time of day (SMS) vs a date-only/midnight value (email).
    static func hasTime(_ date: Date) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0 || (c.second ?? 0) != 0
    }

    /// Which channel(s) a transaction came from — SMS, email, or both (when the same payment was
    /// seen on both and merged). Two single-channel rows with the same amount on different days is
    /// a hint of a duplicate the user can delete.
    static func sourceTags(_ tx: Transaction) -> [SourceTag] {
        let ids = tx.sourceIDs
        let sms = tx.source == "sms" || ids.contains { $0.hasPrefix("sms:") }
        let email = tx.source == "gmail" || ids.contains { !$0.hasPrefix("sms:") }
        var tags: [SourceTag] = []
        if sms { tags.append(.sms) }
        if email { tags.append(.email) }
        return tags.isEmpty ? [.manual] : tags
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tx.category.icon)
                .frame(width: 36, height: 36)
                .background(Brand.accent.opacity(0.15), in: Circle())
                .foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tx.merchant).font(.subheadline.bold())
                    ForEach(Self.sourceTags(tx), id: \.self) { SourceBadge(tag: $0) }
                }
                Text("\(tx.bank) · \(tx.date.formatted(date: .abbreviated, time: Self.hasTime(tx.date) ? .shortened : .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                if tx.isSelfTransfer == true {
                    Label("Own account", systemImage: "arrow.left.arrow.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                } else if tx.toFamily == true {
                    Label(tx.familyMember.map { "To family · \($0)" } ?? "To family",
                          systemImage: "person.2.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.pink)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text((tx.isIncome ? "+" : "") + tx.amountFormatted)
                    .font(.subheadline.bold())
                    .foregroundStyle(tx.isIncome ? .green : .primary)
                if let memberLabel {
                    Text(memberLabel)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Brand.accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(Brand.accent)
                }
            }
        }
    }
}

/// A transaction's capture channel, rendered as a small colored pill.
enum SourceTag: Hashable {
    case sms, email, manual
    var label: String { self == .sms ? "SMS" : self == .email ? "Email" : "Manual" }
    var icon: String { self == .sms ? "message.fill" : self == .email ? "envelope.fill" : "hand.point.up.fill" }
    var color: Color { self == .sms ? .green : self == .email ? .blue : .gray }
}

struct SourceBadge: View {
    let tag: SourceTag
    var body: some View {
        #if os(iOS)
        // Mobile: icon only, to keep rows compact.
        Image(systemName: tag.icon)
            .font(.system(size: 9, weight: .bold))
            .frame(width: 18, height: 18)
            .background(tag.color.opacity(0.15), in: Circle())
            .foregroundStyle(tag.color)
        #else
        Label(tag.label, systemImage: tag.icon)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(tag.color.opacity(0.15), in: Capsule())
            .foregroundStyle(tag.color)
        #endif
    }
}

struct TransactionDetailView: View {
    @EnvironmentObject var store: TransactionStore
    @Environment(\.dismiss) private var dismiss
    let tx: Transaction

    @State private var namingPayee: PayeeRef?

    /// Latest copy from the store so category/tag edits reflect live.
    private var current: Transaction { store.transactions.first { $0.id == tx.id } ?? tx }
    private var partyTags: [String] { store.tags(forMerchant: current.merchant) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: current.category.icon)
                        .font(.title)
                        .frame(width: 56, height: 56)
                        .background((current.isIncome ? Color.green : Brand.accent).opacity(0.15), in: Circle())
                        .foregroundStyle(current.isIncome ? .green : Brand.accent)
                    Text(current.merchant).font(.title3.bold())
                    Text((current.isIncome ? "+" : "") + current.amountFormatted)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(current.isIncome ? .green : .primary)
                    Text(current.date.formatted(date: .complete, time: TransactionRow.hasTime(current.date) ? .shortened : .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }

            Section("Details") {
                LabeledContent("Type", value: current.isIncome ? "Income" : "Expense")
                Picker("Category", selection: Binding(
                    get: { current.category },
                    set: { store.recategorize(current, to: $0) }
                )) {
                    ForEach(SpendCategory.allCases) { cat in
                        Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                    }
                }
                LabeledContent("Bank / source", value: current.bank)
                if current.account != nil {
                    LabeledContent("Account", value: store.memberLabel(for: current.account))
                }
                LabeledContent("Imported via", value: sourceLabel(current.source))
                if let last4 = current.recipientAccountLast4 {
                    Button {
                        namingPayee = PayeeRef(accountLast4: last4, defaultName: current.merchant)
                    } label: {
                        Label("Name account ••\(last4)…", systemImage: "person.text.rectangle")
                    }
                }
            }

            Section("Tags") {
                if partyTags.isEmpty {
                    Text("No tags on \(current.merchant) yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(partyTags, id: \.self) { tag in
                        Label(tag, systemImage: "tag.fill").foregroundStyle(.purple)
                    }
                }
                NavigationLink {
                    PartyDetailView(merchant: current.merchant)
                } label: {
                    Label("Manage tags & history", systemImage: "tag")
                }
            }

            if let snippet = current.rawSnippet, !snippet.isEmpty {
                Section("Original message") {
                    Text(snippet)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button(role: .destructive) {
                    store.delete(current); dismiss()
                } label: {
                    Label("Delete transaction", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $namingPayee) { ref in
            NamePayeeView(accountLast4: ref.accountLast4, defaultName: ref.defaultName)
        }
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "gmail": return "Gmail"
        case "manual": return "Added manually"
        case "sample": return "Sample data"
        default: return source.capitalized
        }
    }
}

/// Identifies the payee-naming sheet target (a recipient account + a suggested name).
struct PayeeRef: Identifiable {
    let id = UUID()
    let accountLast4: String
    let defaultName: String
}

/// Names a recipient account → payee + category, so account-only transfers (society maintenance,
/// rent, a recurring payee the bank reports only by number) become readable. Applies to all
/// history immediately and to future syncs. Reachable from a transaction's context menu/detail.
struct NamePayeeView: View {
    @EnvironmentObject private var store: TransactionStore
    @ObservedObject private var rules = RulesStore.shared
    @Environment(\.dismiss) private var dismiss

    let accountLast4: String
    var defaultName: String = ""

    @State private var name = ""
    @State private var category: SpendCategory = .utilities

    /// A generic rail label is not a useful starting name.
    private static func isGeneric(_ s: String) -> Bool {
        let l = s.lowercased()
        return l == "unknown" || l.hasSuffix("transfer")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Account", value: "••\(accountLast4)")
                    TextField("Payee name", text: $name)
                    Picker("Category", selection: $category) {
                        ForEach(SpendCategory.allCases) { cat in
                            Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                        }
                    }
                } footer: {
                    Text("Every transfer to ••\(accountLast4) — past and future — gets this name and category, and won't count as a family transfer.")
                }
            }
            .navigationTitle("Name payee")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        rules.setPayeeRule(accountLast4: accountLast4, payee: name, category: category)
                        store.applyPayeeRule(accountLast4: accountLast4)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let existing = rules.payeeRule(forAccountLast4: accountLast4) {
                    name = existing.payee
                    category = existing.category
                } else if !Self.isGeneric(defaultName) {
                    name = defaultName
                }
            }
        }
    }
}

struct AddTransactionView: View {
    @EnvironmentObject var store: TransactionStore
    @Environment(\.dismiss) private var dismiss

    @State private var merchant = ""
    @State private var amount = ""
    @State private var category: SpendCategory = .other
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Merchant", text: $merchant)
                TextField("Amount (₹)", text: $amount)
                    .keyboardType(.decimalPad)
                Picker("Category", selection: $category) {
                    ForEach(SpendCategory.allCases) { cat in
                        Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }
            .navigationTitle("Add transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let amt = Double(amount), amt > 0, !merchant.isEmpty else { return }
                        var tx = Transaction(date: date, amount: amt, merchant: merchant,
                                             category: category, bank: "Manual",
                                             source: "manual", rawSnippet: nil)
                        tx.kind = category == .income ? .income : .expense
                        store.add(tx)
                        dismiss()
                    }
                    .disabled(Double(amount) == nil || merchant.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
