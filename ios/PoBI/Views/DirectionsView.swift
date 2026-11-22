import MapKit
import SwiftUI

/// Walking or driving directions from where you are to a place. Biking, rail and bus come later.
struct DirectionsView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case walking, driving
        var id: String { rawValue }
        var title: String { self == .walking ? "Walk" : "Drive" }
        var symbol: String { self == .walking ? "figure.walk" : "car.fill" }
        var transport: MKDirectionsTransportType { self == .walking ? .walking : .automobile }
        var mapsMode: String { self == .walking ? MKLaunchOptionsDirectionsModeWalking : MKLaunchOptionsDirectionsModeDriving }
    }

    @EnvironmentObject private var location: LocationManager
    let place: Place
    /// Remembers the last choice, so drivers don't have to switch every time.
    @AppStorage("directionsMode") private var mode: Mode = .walking

    @State private var route: MKRoute?
    @State private var failure: String?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $position) {
                UserAnnotation()
                Marker(place.name, systemImage: "fork.knife", coordinate: place.coordinate)
                    .tint(Color.accentColor)
                if let route {
                    MapPolyline(route.polyline)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }
            .mapControls {
                MapCompass()
            }
            .overlay(alignment: .bottomTrailing) {
                FollowButton(position: $position)
            }
            .frame(minHeight: 260)

            List {
                Section {
                    Picker("Travel by", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if let route {
                    Section {
                        HStack {
                            Image(systemName: mode.symbol)
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading) {
                                Text(Self.duration(route.expectedTravelTime)).font(.title3.bold())
                                Text(Self.distance(route.distance)).foregroundStyle(.secondary)
                            }
                            Spacer()
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
                            Text(mode == .walking ? "Finding a walking route…" : "Finding a driving route…").foregroundStyle(.secondary)
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
                    Text(mode == .walking ? "Routes come from Apple Maps. Always watch where you're going." : "Routes come from Apple Maps. Don't use your phone while driving: start spoken directions before you set off.")
                }
            }
        }
        .navigationTitle("\(mode.title) to \(place.name)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: mode) { await loadRoute() }
        .onAppear { location.start() }
    }

    private var destination: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = place.name
        return item
    }

    private func loadRoute() async {
        let wanted = mode
        failure = nil
        route = nil
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = mode.transport
        do {
            let response = try await MKDirections(request: request).calculate()
            guard wanted == mode else { return }  // switched Walk/Drive while this was loading
            guard let best = response.routes.first else {
                failure = mode == .walking ? "No walking route found." : "No driving route found."
                return
            }
            route = best
            let padded = best.polyline.boundingMapRect.insetBy(
                dx: -best.polyline.boundingMapRect.width * 0.2 - 200,
                dy: -best.polyline.boundingMapRect.height * 0.2 - 200
            )
            position = .rect(padded)
        } catch {
            guard wanted == mode else { return }
            failure = location.location == nil
                ? "Turn on location for Plate or Break It to get directions."
                : (mode == .walking ? "Couldn't get a walking route. It may be too far to walk. Try Drive." : "Couldn't get a driving route.")
        }
    }

    private func openInMaps() {
        destination.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: mode.mapsMode,
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
