import MapKit
import SwiftUI

struct MapScreen: View {
    @EnvironmentObject private var store: GameStore
    @State private var position: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: GameStore.defaultCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))
    )
    @State private var region: MKCoordinateRegion?
    @State private var visible: [Place] = []
    @State private var selected: Place?

    /// Showing more pins than this makes the map slow and hard to read.
    private let pinLimit = 150
    /// Beyond this zoom-out (about 17 km top to bottom) pins are hidden.
    private let maxSpan = 0.15

    private var zoomedOutTooFar: Bool {
        (region?.span.latitudeDelta ?? 0) > maxSpan
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                UserAnnotation()
                ForEach(visible) { place in
                    Annotation(place.name, coordinate: place.coordinate) {
                        Button {
                            selected = place
                        } label: {
                            PlaceMarker(rating: store.rating(for: place))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // Apple's own restaurant pins aren't game places, so hide them to avoid confusion.
            .mapStyle(.standard(pointsOfInterest: .excluding([
                .restaurant, .cafe, .bakery, .brewery, .winery, .nightlife, .foodMarket,
            ])))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .overlay(alignment: .bottomTrailing) {
                FollowButton(position: $position)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                region = context.region
                refresh()
            }
            .onChange(of: store.catalogLoaded) { refresh() }
            .overlay(alignment: .top) {
                if let hint {
                    Text(hint)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selected) { place in
                NavigationStack {
                    PlaceDetailView(place: place)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var hint: String? {
        if !store.catalogLoaded { return "Loading places…" }
        if zoomedOutTooFar { return "Zoom in to see places" }
        if region != nil && visible.isEmpty { return "No places here yet" }
        return nil
    }

    private func refresh() {
        guard let region, !zoomedOutTooFar else {
            visible = []
            return
        }
        visible = store.catalog.places(in: region, limit: pinLimit)
    }
}

struct PlaceMarker: View {
    let rating: Rating?

    var body: some View {
        Image(systemName: "fork.knife")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(rating.map { $0.verdict.color } ?? Color.gray))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
    }
}
