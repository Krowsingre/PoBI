import MapKit
import SwiftUI

/// Walking directions from where you are to a place. Driving, biking, rail and bus come later.
struct DirectionsView: View {
    @EnvironmentObject private var location: LocationManager
    let place: Place

    @State private var route: MKRoute?
    @State private var failure: String?
    @State private var position: MapCameraPosition = .automatic
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $position) {
                UserAnnotation()
                Marker(place.name, systemImage: "fork.knife", coordinate: place.coordinate)
                    .tint(.accentColor)
                if let route {
                    MapPolyline(route.polyline)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .frame(minHeight: 260)

            List {
                if let route {
                    Section {
                        HStack {
                            Image(systemName: "figure.walk")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading) {
                                Text(Self.duration(route.expectedTravelTime)).font(.title3.bold())
                                Text(Self.distance(route.distance)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Follow me") { position = .userLocation(followsHeading: true, fallback: .automatic) }
                                .buttonStyle(.bordered)
                        }
                    }
                    Section("Steps") {
                        ForEach(Array(route.steps.filter { !$0.instructions.isEmpty }.enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .firstTextBaseline) {
                                Text(step.instructions)
                                Spacer()
                                if step.distance > 0 {
                                    Text(Self.distance(step.distance))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if let failure {
                    Section {
                        Text(failure).foregroundStyle(.secondary)
                        Button("Try again") { Task { await loadRoute() } }
                    }
                } else {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Finding a walking route…").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button {
                        openInMaps()
                    } label: {
                        Label("Spoken directions in Apple Maps", systemImage: "arrow.up.right.square")
                    }
                } footer: {
                    Text("Walking routes come from Apple Maps. Always watch where you're going.")
                }
            }
        }
        .navigationTitle("Walk to \(place.name)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRoute() }
        .onAppear { location.start() }
    }

    private var destination: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = place.name
        return item
    }

    private func loadRoute() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        failure = nil
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = .walking
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let best = response.routes.first else {
                failure = "No walking route found."
                return
            }
            route = best
            let padded = best.polyline.boundingMapRect.insetBy(
                dx: -best.polyline.boundingMapRect.width * 0.2 - 200,
                dy: -best.polyline.boundingMapRect.height * 0.2 - 200
            )
            position = .rect(padded)
        } catch {
            failure = location.location == nil
                ? "Turn on location for Plate or Break It to get directions."
                : "Couldn't get a walking route. It may be too far to walk."
        }
    }

    private func openInMaps() {
        destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking,
        ])
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
