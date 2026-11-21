import SwiftUI

struct PlacesScreen: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager
    @State private var query = ""

    private var shown: [Place] {
        let matching = store.places.filter { place in
            query.isEmpty
                || place.name.localizedCaseInsensitiveContains(query)
                || place.category.localizedCaseInsensitiveContains(query)
                || place.town.localizedCaseInsensitiveContains(query)
        }
        guard let here = location.location else {
            return matching.sorted { $0.name < $1.name }
        }
        return matching.sorted { here.distance(from: $0.location) < here.distance(from: $1.location) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { place in
                NavigationLink(value: place) {
                    PlaceRow(place: place)
                }
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Name, food or town")
            .navigationTitle("Places")
            .navigationDestination(for: Place.self) { place in
                PlaceDetailView(place: place)
            }
        }
    }
}

struct PlaceRow: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager
    let place: Place

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.headline)
                Text("\(place.category) · \(place.town)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let distance = location.distanceText(to: place) {
                    Text(distance).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let rating = store.rating(for: place) {
                VerdictBadge(verdict: rating.verdict, stars: rating.stars, compact: true)
            }
        }
    }
}

struct VerdictBadge: View {
    let verdict: Verdict
    let stars: Int
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: verdict.symbol)
            if !compact { Text(verdict.title).fontWeight(.semibold) }
            Text(String(repeating: "★", count: stars))
        }
        .font(compact ? .caption : .body)
        .foregroundStyle(verdict.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(verdict.title), \(stars) of 3 stars")
    }
}
