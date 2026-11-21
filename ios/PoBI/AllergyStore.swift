import Foundation

/// Your own allergy list (D15). It's kept only on this phone and isn't removed by "Reset test data".
@MainActor
final class AllergyStore: ObservableObject {
    /// The nine major food allergens named by the US FDA.
    static let common = [
        "Milk", "Eggs", "Fish", "Shellfish", "Tree nuts", "Peanuts", "Wheat", "Soy", "Sesame",
    ]

    @Published var selected: Set<String> = [] { didSet { save() } }
    @Published var custom: [String] = [] { didSet { save() } }
    @Published var notes: String = "" { didSet { save() } }

    private static let storageKey = "pobi.allergies.v1"
    private var loading = false

    private struct Saved: Codable {
        var selected: Set<String>
        var custom: [String]
        var notes: String
    }

    init() {
        loading = true
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            selected = saved.selected
            custom = saved.custom
            notes = saved.notes
        }
        loading = false
    }

    /// Everything you've listed, common allergens first in their usual order.
    var all: [String] {
        Self.common.filter(selected.contains) + custom
    }

    var isEmpty: Bool {
        all.isEmpty && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func addCustom(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !all.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        if let match = Self.common.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            selected.insert(match)
        } else {
            custom.append(trimmed)
        }
    }

    private func save() {
        guard !loading else { return }
        let saved = Saved(selected: selected, custom: custom, notes: notes)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
