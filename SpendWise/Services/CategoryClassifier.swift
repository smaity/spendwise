import Foundation
import NaturalLanguage

/// On-device, self-improving spend-category classifier. Three layers, cheapest first:
///
///  1. **Exact-merchant memory** — once you label "Zepto → Groceries", that's remembered
///     with full confidence. Repeat merchants (the bulk of real data) are near-perfect.
///  2. **Embedding kNN** — `NLContextualEmbedding` turns "merchant + alert text" into a
///     semantic vector; new/unseen merchants are classified by their nearest labelled
///     examples, so "…towards pharmacy bill" lands on Health even for an unknown chemist.
///     "Training" is just appending a vector — fully incremental.
///  3. **Keyword seeds** — the kNN is warm-started by embedding `TransactionParser`'s keyword
///     rules, so it generalizes from day one. If embeddings aren't ready, `classify` returns
///     nil and the caller keeps the parser's keyword guess.
///
/// Everything runs on-device (Apple Intelligence not required) and persists locally.
final class CategoryClassifier {

    // Layer 1: normalized merchant -> category (authoritative user labels).
    private var merchantCategory: [String: String] = [:]

    // Layer 2: labelled embedding vectors for kNN.
    private struct Example { let vector: [Float]; let category: String }
    private var examples: [Example] = []
    private var seeded = false

    private let embedding = NLContextualEmbedding(language: .english)
    private var assetsReady = false

    private let fileURL: URL
    private static let maxExamples = 2000
    private static let neighbors = 7
    private static let minSimilarity: Float = 0.30   // reject far-away nearest neighbors

    init(filename: String = "category_model.plist") {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent(filename)
        load()
        setupEmbedding()
        seedIfNeeded()
    }

    // MARK: - Public API

    /// Records one labelled example. Call on user corrections and manual adds (authoritative).
    func train(merchant: String, text: String, category: SpendCategory, weight: Double = 1.0) {
        merchantCategory[Self.key(merchant)] = category.rawValue
        if let v = embed(text) {
            for _ in 0..<max(1, Int(weight.rounded())) {
                examples.append(Example(vector: v, category: category.rawValue))
            }
            if examples.count > Self.maxExamples {
                examples.removeFirst(examples.count - Self.maxExamples)
            }
        }
        save()
    }

    /// Predicts a category with 0–1 confidence, or nil when it has nothing useful to say
    /// (so the caller falls back to the parser's keyword category).
    func classify(merchant: String, text: String) -> (category: SpendCategory, confidence: Double)? {
        if let raw = merchantCategory[Self.key(merchant)], let cat = SpendCategory(rawValue: raw) {
            return (cat, 1.0)
        }
        guard !examples.isEmpty, let v = embed(text) else { return nil }   // cheap exit before embedding
        return knn(v)
    }

    /// Forget everything learned and re-prime from keyword seeds.
    func reset() {
        merchantCategory = [:]; examples = []; seeded = false
        seedIfNeeded()
        save()
    }

    // MARK: - kNN

    private func knn(_ v: [Float]) -> (category: SpendCategory, confidence: Double)? {
        var sims: [(sim: Float, cat: String)] = []
        sims.reserveCapacity(examples.count)
        for ex in examples {
            let n = min(ex.vector.count, v.count)
            var dot: Float = 0
            for i in 0..<n { dot += ex.vector[i] * v[i] }   // vectors are L2-normalized → cosine
            sims.append((dot, ex.category))
        }
        sims.sort { $0.sim > $1.sim }
        guard let best = sims.first, best.sim >= Self.minSimilarity else { return nil }

        var weights: [String: Double] = [:]
        var total = 0.0
        for entry in sims.prefix(Self.neighbors) {
            let w = Double(max(0, entry.sim))
            weights[entry.cat, default: 0] += w
            total += w
        }
        guard total > 0, let top = weights.max(by: { $0.value < $1.value }),
              let cat = SpendCategory(rawValue: top.key) else { return nil }
        return (cat, top.value / total)
    }

    // MARK: - Embedding

    private func embed(_ text: String) -> [Float]? {
        guard assetsReady, let e = embedding else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let result = try? e.embeddingResult(for: trimmed, language: .english) else { return nil }

        let dim = e.dimension
        var sum = [Double](repeating: 0, count: dim)
        var n = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vec, _ in
            if vec.count == dim {
                for i in 0..<dim { sum[i] += vec[i] }
                n += 1
            }
            return true
        }
        guard n > 0 else { return nil }

        var v = [Float](repeating: 0, count: dim)
        var norm: Float = 0
        for i in 0..<dim { let f = Float(sum[i] / Double(n)); v[i] = f; norm += f * f }
        norm = norm.squareRoot()
        if norm > 0 { for i in 0..<dim { v[i] /= norm } }
        return v
    }

    private func setupEmbedding() {
        guard let e = embedding else { return }
        if e.hasAvailableAssets {
            assetsReady = (try? e.load()) != nil
        } else {
            // Not on device yet — download for next launch; until then we fall back to keywords.
            e.requestAssets { _, _ in }
        }
    }

    // MARK: - Seeding ("starting model")

    private func seedIfNeeded() {
        guard !seeded, assetsReady else { return }   // only seed once embeddings are usable
        for rule in TransactionParser.categorySeeds {
            for keyword in rule.keywords {
                if let v = embed(keyword) {
                    examples.append(Example(vector: v, category: rule.category.rawValue))
                }
            }
        }
        seeded = true
        save()
    }

    // MARK: - Helpers

    private static func key(_ merchant: String) -> String {
        merchant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Persistence (binary plist: stores vectors as raw bytes, not base64)

    private struct Persisted: Codable {
        var merchantCategory: [String: String]
        var dim: Int
        var vectors: Data
        var categories: [String]
        var seeded: Bool
    }

    private func save() {
        let dim = embedding?.dimension ?? examples.first?.vector.count ?? 0
        var blob = Data()
        if dim > 0 {
            for ex in examples where ex.vector.count == dim {
                ex.vector.withUnsafeBufferPointer { blob.append(Data(buffer: $0)) }
            }
        }
        let categories = dim > 0 ? examples.filter { $0.vector.count == dim }.map(\.category) : []
        let p = Persisted(merchantCategory: merchantCategory, dim: dim,
                          vectors: blob, categories: categories, seeded: seeded)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(p) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? PropertyListDecoder().decode(Persisted.self, from: data) else { return }
        merchantCategory = p.merchantCategory
        seeded = p.seeded
        guard p.dim > 0, !p.categories.isEmpty else { return }
        let total = p.categories.count * p.dim
        var floats = [Float](repeating: 0, count: total)
        _ = floats.withUnsafeMutableBytes { p.vectors.copyBytes(to: $0) }
        examples = p.categories.enumerated().map { idx, cat in
            let start = idx * p.dim
            return Example(vector: Array(floats[start..<start + p.dim]), category: cat)
        }
    }
}
