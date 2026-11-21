import MapKit
import SwiftUI

struct MapScreen: View {
    @EnvironmentObject private var store: GameStore
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.15, longitude: -74.55),
            span: MKCoordinateSpan(latitudeDelta: 2.4, longitudeDelta: 2.4)
        )
    )
    @State private var selected: Place?

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                UserAnnotation()
                ForEach(store.places) { place in
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
            .mapControls {
                MapUserLocationButton()
                MapCompass()
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
}

struct PlaceMarker: View {
    let rating: Rating?

    var body: some View {
        Image(systemName: "fork.knife")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(rating.map { $0.verdict.color } ?? Color.gray))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
    }
}
