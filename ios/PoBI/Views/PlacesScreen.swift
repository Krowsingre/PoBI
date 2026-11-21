import CoreLocation
import SwiftUI

struct PlacesScreen: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager
    @State private var query = ""
    @State private var shown: [Place] = []
    /// Where the list was last sorted from. It re-sorts after you move about 200 m.
    @State private var sortedFrom: CLLocation?

    /// Nearby places when the search is empty, otherwise matches across New Jersey, closest first.
    private func refresh() {
        let here = location.location
        sortedFrom = here
        shown = store.catalog.search(query, near: here?.coordinate ?? GameStore.defaultCenter, limit: 100)
    }

    var body: some View {
        NavigationStack {
            List(shown) { place in
                NavigationLink(value: place) {
                    PlaceRow(place: place)
                }
            }
            .overlay {
                if !store.catalogLoaded {
                    ProgressView("Loading places…")
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Name, food or town")
            .navigationTitle("Places")
            .task(id: query) {
                // Wait for a pause in typing before searching all of New Jersey.
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return }
                refresh()
            }
            .onChange(of: store.catalogLoaded) { refresh() }
            .onChange(of: location.location) { _, here in
                guard let here else { return }
                if let sortedFrom, here.distance(from: sortedFrom) < 200 { return }
                refresh()
            }
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
