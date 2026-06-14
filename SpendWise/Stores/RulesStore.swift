// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import Foundation
import Combine

/// A user-defined "keyword → category" detection rule.
struct CategoryRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var keyword: String
    var category: SpendCategory
}

/// Maps a recipient account's last-4 digits to a named payee + category, so transfers that the
/// bank reports only by account number (e.g. "IMPS … To A/c xxxxxxxxxxx1234") show a readable
/// name and the right category instead of a generic "IMPS transfer".
struct PayeeRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var accountLast4: String
    var payee: String
    var category: SpendCategory
}

/// User-editable transaction-detection rules, layered on top of the built-in ones.
/// A singleton so the (static) parser and Gmail query can read it; the UI edits it.
final class RulesStore: ObservableObject {
    static let shared = RulesStore()

    @Published var customSenders: [String] = [] { didSet { if loaded { save() } } }
    @Published var customCategoryRules: [CategoryRule] = [] { didSet { if loaded { save() } } }
    @Published var payeeAccountRules: [PayeeRule] = [] { didSet { if loaded { save() } } }

    private var loaded = false
    // App-private storage (Application Support), not the user's Documents folder. On non-sandboxed
    // macOS, `.documentDirectory` is the real ~/Documents — app data must not live there.
    private let fileURL = AppFiles.url("detection_rules.json")

    private init() {
        load()
        loaded = true
    }

    // MARK: Senders

    func addSender(_ raw: String) {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.contains("."),
              !customSenders.contains(email) else { return }
        customSenders.append(email)
    }

    func removeSenders(at offsets: IndexSet) { customSenders.remove(atOffsets: offsets) }

    // MARK: Category rules

    func addCategoryRule(keyword raw: String, category: SpendCategory) {
        let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty,
              !customCategoryRules.contains(where: { $0.keyword == keyword }) else { return }
        customCategoryRules.append(CategoryRule(keyword: keyword, category: category))
    }

    func removeCategoryRules(at offsets: IndexSet) { customCategoryRules.remove(atOffsets: offsets) }

    // MARK: Payee (recipient-account) rules

    /// The payee rule for a recipient account's last-4, if any. Used by the parser.
    func payeeRule(forAccountLast4 last4: String?) -> PayeeRule? {
        guard let last4, !last4.isEmpty else { return nil }
        return payeeAccountRules.first { $0.accountLast4 == last4 }
    }

    func setPayeeRule(accountLast4 raw: String, payee: String, category: SpendCategory) {
        let last4 = String(raw.filter(\.isNumber).suffix(4))
        let name = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard last4.count == 4, !name.isEmpty else { return }
        if let i = payeeAccountRules.firstIndex(where: { $0.accountLast4 == last4 }) {
            payeeAccountRules[i].payee = name
            payeeAccountRules[i].category = category
        } else {
            payeeAccountRules.append(PayeeRule(accountLast4: last4, payee: name, category: category))
        }
    }

    func removePayeeRules(at offsets: IndexSet) { payeeAccountRules.remove(atOffsets: offsets) }

    // MARK: Persistence

    private struct Persisted: Codable {
        var customSenders: [String]
        var customCategoryRules: [CategoryRule]
        var payeeAccountRules: [PayeeRule]?   // optional for backward compatibility
    }

    private func save() {
        let p = Persisted(customSenders: customSenders, customCategoryRules: customCategoryRules,
                          payeeAccountRules: payeeAccountRules)
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        customSenders = p.customSenders
        customCategoryRules = p.customCategoryRules
        payeeAccountRules = p.payeeAccountRules ?? []
    }
}
