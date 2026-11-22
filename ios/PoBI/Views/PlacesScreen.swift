import CoreLocation
import SwiftUI

struct PlacesScreen: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager
    @State private var query = ""
    @State private var shown: [Place] = []
    @State private var scanningReceipt = false
    @State private var receiptLookup: ReceiptLookup?
    /// Where the list was last sorted from. It re-sorts after you move about 200 m.
    @State private var sortedFrom: CLLocation?

    private func lookUp(_ image: UIImage) {
        let lookup = ReceiptLookup()
        receiptLookup = lookup
        let center = location.location?.coordinate ?? GameStore.defaultCenter
        let catalog = store.catalog
        Task {
            let lines = await ReceiptReader.recognizeText(in: image)
            let found = await Task.detached(priority: .userInitiated) {
                ReceiptMatcher.candidates(lines: lines, catalog: catalog, near: center)
            }.value
            lookup.finish(found)
        }
    }

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
            .searchable(text: $query, prompt: "Name, food, town or street")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        scanningReceipt = true
                    } label: {
                        Label("Scan receipt", systemImage: "doc.text.viewfinder")
                    }
                    .disabled(!CameraPicker.isAvailable || !store.catalogLoaded)
                }
            }
            .fullScreenCover(isPresented: $scanningReceipt) {
                CameraPicker { image in lookUp(image) }
                    .ignoresSafeArea()
            }
            .sheet(item: $receiptLookup) { lookup in
                ReceiptLookupView(lookup: lookup)
            }
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
                Text([place.category, place.address.isEmpty ? place.town : "\(place.address), \(place.town)"].joined(separator: " · "))
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

/// The places a scanned receipt might be from.
@MainActor
final class ReceiptLookup: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var results: [Place]?

    func finish(_ places: [Place]) { results = places }
}

struct ReceiptLookupView: View {
    @ObservedObject var lookup: ReceiptLookup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let results = lookup.results {
                    if results.isEmpty {
                        ContentUnavailableView(
                            "No match found",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Couldn't match the name or phone number on this receipt to a place nearby. Try searching by name or street instead.")
                        )
                    } else {
                        List(results) { place in
                            NavigationLink(value: place) {
                                PlaceRow(place: place)
                            }
                        }
                    }
                } else {
                    ProgressView("Reading the receipt…")
                }
            }
            .navigationTitle("Places on this receipt")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Place.self) { place in
                PlaceDetailView(place: place)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
