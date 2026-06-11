import SwiftUI

struct TransactionsListView: View {
    @EnvironmentObject var store: TransactionStore
    @State private var search = ""
    @State private var filterCategory: SpendCategory?
    @State private var showAdd = false
    @State private var taggingParty: PartyRef?

    private var filtered: [Transaction] {
        store.visibleTransactions.filter { tx in
            (filterCategory == nil || tx.category == filterCategory) &&
            (search.isEmpty || tx.merchant.localizedCaseInsensitiveContains(search))
        }
    }

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
                    } label: {
                        Image(systemName: filterCategory == nil
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
        }
    }
}

struct TransactionRow: View {
    let tx: Transaction
    var memberLabel: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tx.category.icon)
                .frame(width: 36, height: 36)
                .background(.teal.opacity(0.15), in: Circle())
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.merchant).font(.subheadline.bold())
                Text("\(tx.bank) · \(tx.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
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
                        .background(.teal.opacity(0.15), in: Capsule())
                        .foregroundStyle(.teal)
                }
            }
        }
    }
}

struct TransactionDetailView: View {
    @EnvironmentObject var store: TransactionStore
    @Environment(\.dismiss) private var dismiss
    let tx: Transaction

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
                        .background((current.isIncome ? Color.green : Color.teal).opacity(0.15), in: Circle())
                        .foregroundStyle(current.isIncome ? .green : .teal)
                    Text(current.merchant).font(.title3.bold())
                    Text((current.isIncome ? "+" : "") + current.amountFormatted)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(current.isIncome ? .green : .primary)
                    Text(current.date.formatted(date: .complete, time: .shortened))
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
