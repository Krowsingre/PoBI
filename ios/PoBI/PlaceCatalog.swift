import CoreLocation
import Foundation
import MapKit

/// The New Jersey food and drink catalogue bundled with the app
/// (Overture Maps Places, built by data/build_nj_places.py).
/// Places are bucketed into a grid of roughly 1 km cells so the map and the
/// list only touch the places near what's on screen.
struct PlaceCatalog: Sendable {
    let places: [Place]
    private let byID: [String: Int]
    private let cells: [Cell: [Int]]
    private let searchKeys: [String]

    /// Grid cells are 0.01° tall and wide (about 1.1 km by 0.85 km in New Jersey).
    private static let cellSize = 0.01

    private struct Cell: Hashable, Sendable {
        let row: Int
        let column: Int

        init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }

        init(latitude: Double, longitude: Double) {
            row = Int((latitude / PlaceCatalog.cellSize).rounded(.down))
            column = Int((longitude / PlaceCatalog.cellSize).rounded(.down))
        }
    }

    static let empty = PlaceCatalog(places: [])

    init(places: [Place]) {
        self.places = places
        var byID: [String: Int] = [:]
        var cells: [Cell: [Int]] = [:]
        byID.reserveCapacity(places.count)
        for (index, place) in places.enumerated() {
            byID[place.id] = index
            cells[Cell(latitude: place.latitude, longitude: place.longitude), default: []].append(index)
        }
        self.byID = byID
        self.cells = cells
        searchKeys = places.map { "\($0.name) \($0.category) \($0.town)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    }

    /// Reads the bundled tab-separated file: id, name, category, town, latitude, longitude.
    static func loadBundled() -> PlaceCatalog {
        guard let url = Bundle.main.url(forResource: "nj_places", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .empty
        }
        var places: [Place] = []
        places.reserveCapacity(50_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 6,
                  let latitude = Double(fields[4]),
                  let longitude = Double(fields[5]) else { continue }
            places.append(Place(
                id: String(fields[0]),
                name: String(fields[1]),
                category: String(fields[2]),
                town: String(fields[3]),
                latitude: latitude,
                longitude: longitude
            ))
        }
        return PlaceCatalog(places: places)
    }

    func place(id: String) -> Place? {
        byID[id].map { places[$0] }
    }

    /// Places inside the region, closest to its center first.
    func places(in region: MKCoordinateRegion, limit: Int) -> [Place] {
        let center = region.center
        let minLat = center.latitude - region.span.latitudeDelta / 2
        let maxLat = center.latitude + region.span.latitudeDelta / 2
        let minLon = center.longitude - region.span.longitudeDelta / 2
        let maxLon = center.longitude + region.span.longitudeDelta / 2
        let low = Cell(latitude: minLat, longitude: minLon)
        let high = Cell(latitude: maxLat, longitude: maxLon)
        var found: [Int] = []
        for row in low.row...high.row {
            for column in low.column...high.column {
                guard let indices = cells[Cell(row: row, column: column)] else { continue }
                for index in indices {
                    let place = places[index]
                    if place.latitude >= minLat, place.latitude <= maxLat,
                       place.longitude >= minLon, place.longitude <= maxLon {
                        found.append(index)
                    }
                }
            }
        }
        return closest(found, to: center, limit: limit)
    }

    /// The nearest places to a point, searching outward ring by ring.
    func nearest(to coordinate: CLLocationCoordinate2D, limit: Int) -> [Place] {
        let origin = Cell(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let scale = cos(coordinate.latitude * .pi / 180)
        var found: [Int] = []
        for radius in 0...60 {
            for row in (origin.row - radius)...(origin.row + radius) {
                for column in (origin.column - radius)...(origin.column + radius) {
                    let onRing = abs(row - origin.row) == radius || abs(column - origin.column) == radius
                    guard onRing, let indices = cells[Cell(row: row, column: column)] else { continue }
                    found.append(contentsOf: indices)
                }
            }
            guard found.count >= limit else { continue }
            // Every place closer than `covered` sits in a cell already searched, so once the
            // limit-th closest place is within it, no unsearched cell can hold a closer one.
            let covered = Double(radius) * Self.cellSize * min(1, scale)
            let distances = found.map { squaredDistance($0, from: coordinate, scale: scale) }.sorted()
            if distances[limit - 1] <= covered * covered { break }
        }
        return closest(found, to: coordinate, limit: limit)
    }

    /// Places whose name, food or town contains the query, closest first.
    func search(_ query: String, near coordinate: CLLocationCoordinate2D, limit: Int) -> [Place] {
        let needle = query.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return nearest(to: coordinate, limit: limit) }
        let matches = searchKeys.indices.filter { searchKeys[$0].contains(needle) }
        return closest(matches, to: coordinate, limit: limit)
    }

    private func closest(_ indices: [Int], to coordinate: CLLocationCoordinate2D, limit: Int) -> [Place] {
        // Squared degree distance, with longitude scaled for latitude, is enough for ordering.
        let scale = cos(coordinate.latitude * .pi / 180)
        return indices
            .map { (index: $0, distance: squaredDistance($0, from: coordinate, scale: scale)) }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map { places[$0.index] }
    }

    /// Squared degree distance with longitude scaled for latitude. Enough for ordering nearby places.
    private func squaredDistance(_ index: Int, from coordinate: CLLocationCoordinate2D, scale: Double) -> Double {
        let place = places[index]
        let dLat = place.latitude - coordinate.latitude
        let dLon = (place.longitude - coordinate.longitude) * scale
        return dLat * dLat + dLon * dLon
    }
}
