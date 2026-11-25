import CoreLocation
import SwiftUI

/// Shown when a receipt file is shared into the app: reads it, suggests the place, then rates.
struct SharedReceiptView: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager
    @Environment(\.dismiss) private var dismiss
    let url: URL

    @State private var receipt: DigitalReceipt?
    @State private var failure: String?
    @State private var candidates: [Place] = []
    @State private var chosen: Place?

    /// Central New Jersey, for when location is off.
    private static let fallback = CLLocationCoordinate2D(latitude: 40.22, longitude: -74.66)

    var body: some View {
        if let chosen {
            RateView(place: chosen, sharedReceipt: url)
        } else {
            NavigationStack {
                List {
                    if let failure {
                        Section { Text(failure).foregroundStyle(.secondary) }
                    } else if let receipt {
                        Section {
                            Image(uiImage: receipt.image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Section {
                            if candidates.isEmpty {
                                Text("Couldn't tell which place this is from. Open the place in the app and tap Rate, then choose \"Use a digital receipt\".")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(candidates) { place in
                                Button {
                                    chosen = place
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.name).font(.headline)
                                        Text(place.address.isEmpty ? place.town : "\(place.address), \(place.town)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(store.rating(for: place) != nil)
                            }
                        } header: {
                            Text("Which place is it from?")
                        } footer: {
                            Text("Digital receipts are checked by a reviewer before the rating counts. You still need a food or storefront photo taken at the place.")
                        }
                    } else {
                        HStack {
                            ProgressView()
                            Text("Reading the receipt…").foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Digital receipt")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .task {
                    do {
                        let read = try await DigitalReceipt.load(url)
                        receipt = read
                        candidates = ReceiptMatcher.candidates(
                            lines: read.lines, catalog: store.catalog,
                            near: location.location?.coordinate ?? Self.fallback, limit: 8
                        )
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }
        }
    }
}
