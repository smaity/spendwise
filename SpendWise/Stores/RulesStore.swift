import Foundation
import Combine

/// A user-defined "keyword → category" detection rule.
struct CategoryRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var keyword: String
    var category: SpendCategory
}

/// User-editable transaction-detection rules, layered on top of the built-in ones.
/// A singleton so the (static) parser and Gmail query can read it; the UI edits it.
final class RulesStore: ObservableObject {
    static let shared = RulesStore()

    @Published var customSenders: [String] = [] { didSet { if loaded { save() } } }
    @Published var customCategoryRules: [CategoryRule] = [] { didSet { if loaded { save() } } }

    private var loaded = false
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("detection_rules.json")
    }()

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

    // MARK: Persistence

    private struct Persisted: Codable {
        var customSenders: [String]
        var customCategoryRules: [CategoryRule]
    }

    private func save() {
        let p = Persisted(customSenders: customSenders, customCategoryRules: customCategoryRules)
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        customSenders = p.customSenders
        customCategoryRules = p.customCategoryRules
    }
}
