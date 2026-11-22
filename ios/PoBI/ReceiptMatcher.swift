import CoreLocation
import Foundation

/// Checks that a receipt comes from the place being rated, using the text read off it.
/// The business name must appear. If the receipt shows a phone number or street address,
/// it must not belong to a different branch of the same business.
enum ReceiptMatcher {
    enum Result: Equatable {
        /// The name matches. `branchConfirmed` is true when the phone or address also matches this branch.
        case matches(branchConfirmed: Bool)
        /// The receipt names a different branch of the same business.
        case otherBranch(Place)
        /// The place's name couldn't be found on the receipt.
        case nameNotFound
    }

    /// Words too common to identify a business on their own.
    private static let genericWords: Set<String> = [
        "the", "and", "restaurant", "cafe", "café", "grill", "pizza", "pizzeria", "bar", "kitchen",
        "deli", "inc", "llc", "corp", "nj", "of", "house", "co", "company", "food", "foods",
        "bakery", "diner", "shop", "store", "market", "express", "&",
    ]

    /// Lower-case letters and digits only, so "DUNKIN'" and "Dunkin" compare equal.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func names(_ place: Place, appearIn text: String) -> Bool {
        let haystack = normalize(text)
        let fullName = normalize(place.name)
        if fullName.count >= 3, haystack.contains(fullName) { return true }
        let brand = normalize(place.brand)
        if brand.count >= 3, haystack.contains(brand) { return true }
        // Otherwise most of the distinctive words in the name must appear.
        let words = place.name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { normalize(String($0)) }
            .filter { $0.count >= 3 && !genericWords.contains($0) }
        guard let longest = words.map(\.count).max(), longest >= 4 else { return false }
        let found = words.filter { haystack.contains($0) }.count
        return found * 2 >= words.count && found > 0
    }

    /// Every 10-digit US phone number on the receipt.
    static func phones(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(?:1[\s.\-]?)?\(?(\d{3})\)?[\s.\-]?(\d{3})[\s.\-]?(\d{4})(?!\d)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var result: Set<String> = []
        for match in regex.matches(in: text, range: range) {
            let parts = (1...3).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
            if parts.count == 3 { result.insert(parts.joined()) }
        }
        return result
    }

    /// The house number and first street word of an address, like "909state" for "909 State Route 33".
    static func addressKey(_ address: String) -> String? {
        let words = address.lowercased().split(whereSeparator: { $0 == " " || $0 == "," })
        guard words.count >= 2, let number = words.first, number.allSatisfy(\.isNumber) else { return nil }
        let street = normalize(String(words[1]))
        guard street.count >= 2 else { return nil }
        return String(number) + street
    }

    static func check(lines: [String], place: Place, catalog: PlaceCatalog) -> Result {
        let text = lines.joined(separator: "\n")
        guard names(place, appearIn: text) else { return .nameNotFound }
        let squashed = normalize(text)
        let receiptPhones = phones(in: text)

        // The catalogue sometimes lists one shop twice, so listings at the same spot count as this place.
        func sameSpot(_ other: Place) -> Bool {
            if other.id == place.id { return true }
            if let a = addressKey(other.address), a == addressKey(place.address) { return true }
            return other.location.distance(from: place.location) < 150
        }

        // A street address is the strongest sign of which branch it was. Check it before phone numbers,
        // because some branches share one phone number.
        if let key = addressKey(place.address), squashed.contains(key) { return .matches(branchConfirmed: true) }
        let branches = catalog.branches(of: place).filter { !sameSpot($0) }
        if let other = branches.first(where: { other in
            guard let key = addressKey(other.address), key.count >= 4 else { return false }
            return squashed.contains(key)
        }) {
            return .otherBranch(other)
        }

        // Phone numbers: one that only this place uses confirms it; one only another branch uses rejects it.
        for phone in receiptPhones {
            let listed = catalog.places(withPhone: phone).filter { sameBusiness($0, place) || $0.id == place.id }
            let here = listed.contains(where: sameSpot)
            let elsewhere = listed.filter { !sameSpot($0) }
            if here && elsewhere.isEmpty { return .matches(branchConfirmed: true) }
            if !here, let other = elsewhere.first { return .otherBranch(other) }
        }

        // No branch details on the receipt. The food photo taken at the place shows which branch it was.
        return .matches(branchConfirmed: false)
    }

    private static func sameBusiness(_ a: Place, _ b: Place) -> Bool {
        let keyA = normalize(a.brand.isEmpty ? a.name : a.brand)
        let keyB = normalize(b.brand.isEmpty ? b.name : b.brand)
        return !keyA.isEmpty && keyA == keyB
    }

    /// Places near you whose name appears on the receipt, or whose phone number does.
    static func candidates(lines: [String], catalog: PlaceCatalog, near coordinate: CLLocationCoordinate2D, limit: Int = 20) -> [Place] {
        let text = lines.joined(separator: "\n")
        var found: [Place] = []
        var seen: Set<String> = []
        for phone in phones(in: text) {
            for place in catalog.places(withPhone: phone) where seen.insert(place.id).inserted {
                found.append(place)
            }
        }
        for place in catalog.nearest(to: coordinate, limit: 4000)
        where !seen.contains(place.id) && normalize(place.name).count >= 4 && names(place, appearIn: text) {
            seen.insert(place.id)
            found.append(place)
            if found.count >= limit { break }
        }
        return found
    }
}
