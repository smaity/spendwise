// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import SwiftUI
import Combine

@MainActor
final class TransactionStore: ObservableObject {
    @Published var transactions: [Transaction] = []
    @Published var isSyncing = false
    @Published var lastSync: Date?
    @Published var syncError: String?
    /// e.g. "March 2026" — the month currently being imported (nil when idle).
    @Published var syncProgress: String?
    /// nil = whole family; otherwise show only this account's spending.
    @Published var memberFilter: String?
    /// User-assigned tags keyed by normalized merchant ("party"). A party tagged once
    /// stays tagged as new transactions from it arrive on future syncs.
    @Published var partyTags: [String: [String]] = [:]

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("transactions.json")
    }()

    private static let partyTagsKey = "party_tags"

    let gmail = GmailService()
    /// On-device, self-improving category classifier (warm-started from keyword seeds).
    /// Used as the fallback when Apple Intelligence isn't available.
    private let classifier = CategoryClassifier()
    /// Primary classifier: Apple Intelligence's on-device model (iOS 26+). Falls through
    /// to `classifier` when unavailable.
    private let aiClassifier = AICategoryClassifier()
    /// Confidence below which we trust the parser's keyword category instead of the model.
    private static let classifierThreshold = 0.55
    private var cancellables = Set<AnyCancellable>()

    init() {
        load()
        if let data = UserDefaults.standard.data(forKey: Self.partyTagsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            partyTags = decoded
        }
        if transactions.isEmpty {
            transactions = SampleData.transactions   // demo data until Gmail is connected
        }
        // Re-render views observing this store when accounts change (connect/rename/remove).
        gmail.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: Persistence

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Transaction].self, from: data) else { return }
        transactions = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(transactions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Mutations

    func add(_ tx: Transaction) {
        transactions.append(tx)
        transactions.sort { $0.date > $1.date }
        if !tx.isIncome {
            classifier.train(merchant: tx.merchant, text: Self.trainingText(tx), category: tx.category)
        }
        save()
    }

    func delete(_ tx: Transaction) {
        transactions.removeAll { $0.id == tx.id }
        save()
    }

    func recategorize(_ tx: Transaction, to category: SpendCategory) {
        guard let i = transactions.firstIndex(where: { $0.id == tx.id }) else { return }
        transactions[i].category = category
        transactions[i].kind = category == .income ? .income : .expense   // keep direction consistent
        // A user correction is the strongest training signal — teach the model.
        if category != .income {
            classifier.train(merchant: transactions[i].merchant,
                             text: Self.trainingText(transactions[i]), category: category, weight: 2.0)
        }
        save()
    }

    /// Text the classifier learns from / predicts on: merchant plus the original alert body.
    private static func trainingText(_ tx: Transaction) -> String {
        tx.merchant + " " + (tx.rawSnippet ?? "")
    }

    /// Applies the learned model to a freshly fetched expense, overriding the parser's
    /// keyword guess only when the model is confident. Income categories are left as-is.
    private func categorized(_ tx: Transaction) -> Transaction {
        guard !tx.isIncome else { return tx }
        guard let prediction = classifier.classify(merchant: tx.merchant, text: Self.trainingText(tx)),
              prediction.confidence >= Self.classifierThreshold else { return tx }
        var t = tx
        t.category = prediction.category
        return t
    }

    /// Disconnects a Gmail account and removes its transactions.
    func removeMember(_ account: GmailAccount) {
        gmail.disconnect(account)
        transactions.removeAll { $0.account == account.email }
        if memberFilter == account.email { memberFilter = nil }
        save()
    }

    // MARK: Gmail sync

    func syncFromGmail(daysBack: Int = 90) async {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }
        do {
            let fetched = try await gmail.fetchTransactions(daysBack: daysBack)
            let addedIDs = commitMerge(fetched)
            await refineWithAI(addedIDs)
            lastSync = Date()
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Wipes synced (Gmail/sample) transactions and re-imports the last `monthsBack` months.
    /// Manual entries and party tags are preserved — tags re-attach to re-synced parties by name.
    func resyncAll(monthsBack: Int = 12) async {
        transactions.removeAll { $0.source != "manual" }
        save()
        if gmail.isConnected {
            await syncFromGmail(monthsBack: monthsBack)
        }
    }

    /// Imports `monthsBack` months of history one calendar month at a time (newest first),
    /// so each Gmail query stays under the result cap. Pass 12 to pull the last year.
    func syncFromGmail(monthsBack: Int) async {
        guard gmail.isConnected else { return }
        isSyncing = true
        syncError = nil
        defer { isSyncing = false; syncProgress = nil }

        let cal = Calendar.current
        let now = Date()
        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        var fetchedAll: [Transaction] = []
        var errors: [String] = []

        for m in 0..<max(monthsBack, 1) {
            guard let monthStart = cal.date(byAdding: .month, value: -m, to: thisMonthStart),
                  let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart) else { continue }
            let before = min(nextMonth, now)
            syncProgress = monthStart.formatted(.dateTime.month(.wide).year())

            for account in gmail.accounts {
                do {
                    fetchedAll += try await gmail.fetchTransactions(for: account, after: monthStart, before: before)
                } catch {
                    errors.append("\(account.label): \(error.localizedDescription)")
                }
            }
        }

        let addedIDs = commitMerge(fetchedAll)
        if addedIDs.isEmpty, let first = errors.first { syncError = first }
        await refineWithAI(addedIDs)
        lastSync = Date()
    }

    /// Merges fetched transactions into the store, persisting only if anything changed.
    /// Returns the IDs of the genuinely new transactions added.
    @discardableResult
    private func commitMerge(_ fetched: [Transaction]) -> [UUID] {
        let result = merge(fetched)
        if result.changed {
            if result.added > 0 {
                transactions.removeAll { $0.source == "sample" }   // drop demo data once real data arrives
            }
            transactions.sort { $0.date > $1.date }
            save()
        }
        return result.addedIDs
    }

    /// Primary categorization: upgrades freshly-imported expenses with Apple Intelligence
    /// when it's available, overwriting the embedding classifier's guess. A no-op (keeps the
    /// fallback guess) on iOS < 26 or when Apple Intelligence is off. AI's decisions also
    /// train the embedding classifier, so the fallback keeps improving.
    private func refineWithAI(_ ids: [UUID]) async {
        guard !ids.isEmpty, aiClassifier.isAvailable() else { return }
        var changed = false
        for id in ids {
            guard let i = transactions.firstIndex(where: { $0.id == id }), !transactions[i].isIncome,
                  let cat = await aiClassifier.classify(merchant: transactions[i].merchant,
                                                        snippet: transactions[i].rawSnippet ?? "")
            else { continue }
            if transactions[i].category != cat { transactions[i].category = cat; changed = true }
            classifier.train(merchant: transactions[i].merchant,
                             text: Self.trainingText(transactions[i]), category: cat)
        }
        if changed { save() }
    }

    /// De-duplicates by stable Gmail message-ID. For rows imported before IDs were tracked,
    /// matches on the legacy heuristic key and backfills the ID in place (one-time migration)
    /// rather than creating a duplicate. Manual/sample rows fall back to the heuristic key.
    private func merge(_ fetched: [Transaction]) -> (added: Int, changed: Bool, addedIDs: [UUID]) {
        var knownIDs = Set(transactions.compactMap(\.sourceID))
        var knownHeuristic = Set(transactions.map(Self.heuristicKey))
        // Legacy Gmail rows (no sourceID yet) eligible for ID backfill — never sample/manual.
        var legacyIndex: [String: Int] = [:]
        for (i, tx) in transactions.enumerated() where tx.sourceID == nil && tx.source == "gmail" {
            legacyIndex[Self.heuristicKey(tx)] = i
        }

        var added = 0
        var changed = false
        var addedIDs: [UUID] = []
        for tx in fetched {
            if let sid = tx.sourceID {
                if knownIDs.contains(sid) { continue }
                if let i = legacyIndex.removeValue(forKey: Self.heuristicKey(tx)) {
                    transactions[i].sourceID = sid       // migrate existing row, don't duplicate
                    knownIDs.insert(sid)
                    changed = true
                    continue
                }
                let row = categorized(tx)
                transactions.append(row)
                knownIDs.insert(sid)
                knownHeuristic.insert(Self.heuristicKey(tx))
                addedIDs.append(row.id)
                added += 1; changed = true
            } else {
                let key = Self.heuristicKey(tx)
                if knownHeuristic.contains(key) { continue }
                let row = categorized(tx)
                transactions.append(row)
                knownHeuristic.insert(key)
                addedIDs.append(row.id)
                added += 1; changed = true
            }
        }
        return (added, changed, addedIDs)
    }

    /// Fallback identity for rows without a stable provider ID (manual entries, pre-migration).
    private static func heuristicKey(_ tx: Transaction) -> String {
        let day = Calendar.current.startOfDay(for: tx.date).timeIntervalSince1970
        return "\(day)|\(tx.amount)|\(tx.merchant.lowercased())|\(tx.account ?? "")"
    }

    // MARK: Party tags

    private static func partyKey(_ merchant: String) -> String {
        merchant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tags assigned to a merchant ("party").
    func tags(forMerchant merchant: String) -> [String] {
        partyTags[Self.partyKey(merchant)] ?? []
    }

    func addTag(_ raw: String, toMerchant merchant: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        let key = Self.partyKey(merchant)
        var tags = partyTags[key] ?? []
        guard !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        tags.append(tag)
        partyTags[key] = tags
        saveTags()
    }

    func removeTag(_ tag: String, fromMerchant merchant: String) {
        let key = Self.partyKey(merchant)
        partyTags[key]?.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        if partyTags[key]?.isEmpty == true { partyTags[key] = nil }
        saveTags()
    }

    /// Every distinct tag in use, alphabetised.
    var allTags: [String] {
        Set(partyTags.values.flatMap { $0 })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func saveTags() {
        if let data = try? JSONEncoder().encode(partyTags) {
            UserDefaults.standard.set(data, forKey: Self.partyTagsKey)
        }
    }

    // MARK: Tag / party drill-down (respect the member filter)

    func transactions(forMerchant merchant: String) -> [Transaction] {
        let key = Self.partyKey(merchant)
        return visibleTransactions.filter { Self.partyKey($0.merchant) == key }
    }

    func transactions(taggedWith tag: String) -> [Transaction] {
        visibleTransactions.filter { tx in
            tags(forMerchant: tx.merchant).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    /// Spend per month for the last `count` months ending at `date` (inclusive), oldest first.
    /// Months with no spend are included as 0 so the trend line stays continuous.
    func monthlyTotals(lastMonths count: Int, endingAt date: Date = Date()) -> [(month: Date, total: Double)] {
        let cal = Calendar.current
        guard let end = cal.date(from: cal.dateComponents([.year, .month], from: date)) else { return [] }
        var buckets: [Date: Double] = [:]
        for i in 0..<max(count, 1) {
            if let m = cal.date(byAdding: .month, value: -i, to: end) { buckets[m] = 0 }
        }
        for tx in visibleTransactions where !tx.isIncome {
            guard let m = cal.date(from: cal.dateComponents([.year, .month], from: tx.date)),
                  buckets[m] != nil else { continue }
            buckets[m, default: 0] += tx.amount
        }
        return buckets.map { (month: $0.key, total: $0.value) }.sorted { $0.month < $1.month }
    }

    /// Spend bucketed by calendar month (ascending) — feeds the over-time drill-down chart.
    func monthlySpend(of txs: [Transaction]) -> [(month: Date, total: Double)] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: txs) {
            cal.date(from: cal.dateComponents([.year, .month], from: $0.date)) ?? $0.date
        }
        return groups.map { (month: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.month < $1.month }
    }

    // MARK: Family members

    /// Distinct accounts present in the data (emails), sorted.
    var memberEmails: [String] {
        Array(Set(transactions.compactMap(\.account))).sorted()
    }

    /// Display name for an account email: connected-account label, else mailbox prefix.
    func memberLabel(for email: String?) -> String {
        guard let email, !email.isEmpty else { return "Manual" }
        if let label = gmail.label(forEmail: email) { return label }
        return email.split(separator: "@").first.map { String($0).capitalized } ?? email
    }

    /// Transactions visible under the current member filter.
    var visibleTransactions: [Transaction] {
        guard let memberFilter else { return transactions }
        return transactions.filter { $0.account == memberFilter }
    }

    /// Visible spends only (income excluded) — the basis for all spend analytics.
    var visibleExpenses: [Transaction] { visibleTransactions.filter { !$0.isIncome } }

    /// Per-member SPEND totals for a month (ignores the filter — used for the family breakdown card).
    func memberTotals(inMonthOf date: Date) -> [(email: String, label: String, total: Double)] {
        let cal = Calendar.current
        let monthTxs = transactions.filter { !$0.isIncome && cal.isDate($0.date, equalTo: date, toGranularity: .month) }
        let groups = Dictionary(grouping: monthTxs) { $0.account ?? "" }
        return groups.map { (email: $0.key, label: memberLabel(for: $0.key), total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
    }

    // MARK: Analytics (respect the member filter)

    /// Spends in a month (income excluded) — feeds totals, donut, daily/category breakdowns.
    func transactions(inMonthOf date: Date) -> [Transaction] {
        let cal = Calendar.current
        return visibleExpenses.filter { cal.isDate($0.date, equalTo: date, toGranularity: .month) }
    }

    func total(inMonthOf date: Date) -> Double {
        transactions(inMonthOf: date).reduce(0) { $0 + $1.amount }
    }

    /// ML forecast: run-rate projection of total spend for the in-progress month, or nil if
    /// `date` isn't the current month or it's too early/late to project. Respects the filter.
    func projectedMonthEnd(for date: Date) -> Double? {
        let cal = Calendar.current
        let today = Date()
        guard cal.isDate(date, equalTo: today, toGranularity: .month),
              let range = cal.range(of: .day, in: .month, for: today) else { return nil }
        let spent = total(inMonthOf: date)
        let dayOfMonth = Double(cal.component(.day, from: today))
        let daysInMonth = Double(range.count)
        guard spent > 0, dayOfMonth >= 3, dayOfMonth < daysInMonth - 1 else { return nil }
        return spent / dayOfMonth * daysInMonth
    }

    /// Total income credited in a month (respects the member filter).
    func income(inMonthOf date: Date) -> Double {
        let cal = Calendar.current
        return visibleTransactions
            .filter { $0.isIncome && cal.isDate($0.date, equalTo: date, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    func categorySummaries(inMonthOf date: Date) -> [CategorySummary] {
        let txs = transactions(inMonthOf: date)
        let total = txs.reduce(0) { $0 + $1.amount }
        guard total > 0 else { return [] }
        let groups = Dictionary(grouping: txs, by: \.category)
        return groups.map { cat, items in
            let sum = items.reduce(0) { $0 + $1.amount }
            return CategorySummary(category: cat, total: sum, count: items.count,
                                   percentOfSpend: sum / total * 100)
        }
        .sorted { $0.total > $1.total }
    }

    /// Daily totals for the current month — feeds the trend chart.
    func dailyTotals(inMonthOf date: Date) -> [(day: Date, total: Double)] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: transactions(inMonthOf: date)) {
            cal.startOfDay(for: $0.date)
        }
        return groups.map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.0 < $1.0 }
    }
}

// MARK: - Sample data (shown before Gmail is connected)

enum SampleData {
    static var transactions: [Transaction] {
        let cal = Calendar.current
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: Date())! }
        let rows: [(Int, Double, String, SpendCategory, String)] = [
            (0, 420, "Swiggy", .food, "HDFC"),
            (1, 1250, "Big Bazaar", .groceries, "HDFC"),
            (1, 199, "Spotify", .entertainment, "ICICI"),
            (2, 310, "Uber", .transport, "HDFC"),
            (3, 2899, "Amazon", .shopping, "ICICI"),
            (4, 650, "Zomato", .food, "HDFC"),
            (5, 999, "Airtel Recharge", .utilities, "SBI"),
            (6, 540, "Blinkit", .groceries, "HDFC"),
            (8, 180, "Rapido", .transport, "ICICI"),
            (9, 3500, "Myntra", .shopping, "HDFC"),
            (10, 649, "Netflix", .entertainment, "ICICI"),
            (11, 850, "Apollo Pharmacy", .health, "SBI"),
            (12, 380, "Swiggy", .food, "HDFC"),
            (14, 2100, "BESCOM Electricity", .utilities, "HDFC"),
            (15, 5000, "Groww SIP", .investment, "ICICI"),
            (17, 720, "Zomato", .food, "HDFC"),
            (19, 1500, "Indian Oil Petrol", .transport, "SBI"),
            (21, 460, "Zepto", .groceries, "HDFC"),
            (23, 1299, "BookMyShow", .entertainment, "ICICI"),
            (25, 899, "Flipkart", .shopping, "HDFC"),
            (32, 410, "Swiggy", .food, "HDFC"),
            (33, 199, "Spotify", .entertainment, "ICICI"),
            (35, 2750, "Amazon", .shopping, "ICICI"),
            (36, 980, "Airtel Recharge", .utilities, "SBI"),
            (38, 5000, "Groww SIP", .investment, "ICICI"),
            (40, 649, "Netflix", .entertainment, "ICICI"),
            (42, 1850, "BigBasket", .groceries, "HDFC"),
            (45, 600, "Ola", .transport, "HDFC"),
            (48, 1100, "Dominos", .food, "ICICI"),
            (52, 3200, "MakeMyTrip", .travel, "HDFC"),
        ]
        // Two sample members to demonstrate family segregation.
        var txs = rows.map {
            Transaction(date: daysAgo($0.0), amount: $0.1, merchant: $0.2,
                        category: $0.3, bank: $0.4, source: "sample", rawSnippet: nil)
        }
        for i in txs.indices {
            txs[i].account = i % 3 == 0 ? "family@sample.in" : "you@sample.in"
        }
        return txs
    }
}
