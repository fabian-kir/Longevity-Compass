import Foundation

/// Bundled Open Food Facts ingredient taxonomy (`Resources/OFFIngredientTaxonomy.json`,
/// built by `scripts/trim_off_taxonomy.py`). Loaded once; immutable afterwards.
nonisolated final class IngredientTaxonomy: Sendable {
    struct Entry: Decodable, Sendable {
        let parents: [String]
        let en: String?
        let de: String?
    }

    private struct File: Decodable {
        let license: String
        let ingredients: [String: Entry]
        let freeFromChildren: [String: [String]]
    }

    static let shared: IngredientTaxonomy = {
        guard let url = Bundle.main.url(forResource: "OFFIngredientTaxonomy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let taxonomy = try? IngredientTaxonomy(data: data) else {
            assertionFailure("OFFIngredientTaxonomy.json missing from bundle or failed to decode")
            return IngredientTaxonomy(license: "", entries: [:], freeFromChildren: [:])
        }
        return taxonomy
    }()

    let license: String
    private let entries: [String: Entry]
    private let englishIndex: [String: String]
    private let germanIndex: [String: String]
    private let freeFromByLabel: [String: FreeFromLabel]

    convenience init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        self.init(license: file.license, entries: file.ingredients, freeFromChildren: file.freeFromChildren)
    }

    init(license: String, entries: [String: Entry], freeFromChildren: [String: [String]]) {
        self.license = license
        self.entries = entries
        // Sorted so that two IDs sharing a name always resolve to the same one.
        var english: [String: String] = [:]
        var german: [String: String] = [:]
        for id in entries.keys.sorted() {
            guard let entry = entries[id] else { continue }
            if let name = entry.en { english[Self.normalize(name)] = english[Self.normalize(name)] ?? id }
            if let name = entry.de { german[Self.normalize(name)] = german[Self.normalize(name)] ?? id }
        }
        englishIndex = english
        germanIndex = german
        var byLabel: [String: FreeFromLabel] = [:]
        for label in FreeFromLabel.allCases {
            byLabel[label.rawValue] = label
            for child in freeFromChildren[label.rawValue] ?? [] { byLabel[child] = label }
        }
        freeFromByLabel = byLabel
    }

    var count: Int { entries.count }

    func contains(_ id: String) -> Bool { entries[id] != nil }

    func parents(of id: String) -> [String] { entries[id]?.parents ?? [] }

    /// All transitive parents, excluding `id` itself.
    func ancestors(of id: String) -> Set<String> {
        var seen = Set<String>()
        var stack = parents(of: id)
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            stack.append(contentsOf: parents(of: next))
        }
        return seen
    }

    /// English name, falling back to German.
    func name(of id: String) -> String? {
        entries[id]?.en ?? entries[id]?.de
    }

    /// Exact match on the normalised name, English then German. A name ending
    /// in "s" is retried without it ("onions" → "onion"). Nothing fuzzier.
    func id(forName name: String) -> String? {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return nil }
        if let id = englishIndex[key] ?? germanIndex[key] { return id }
        guard key.hasSuffix("s") else { return nil }
        let singular = String(key.dropLast())
        return englishIndex[singular] ?? germanIndex[singular]
    }

    /// Free-from label an Open Food Facts label tag stands for, child labels included
    /// (e.g. `en:certified-gluten-free` → `.glutenFree`).
    func freeFromLabel(forLabelTag tag: String) -> FreeFromLabel? {
        freeFromByLabel[tag]
    }

    /// Lowercased, trimmed, inner whitespace collapsed to single spaces.
    static func normalize(_ name: String) -> String {
        name.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
