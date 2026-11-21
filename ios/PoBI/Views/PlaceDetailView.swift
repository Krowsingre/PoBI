import SwiftUI

struct PlaceDetailView: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager
    let place: Place

    @State private var showRate = false
    @State private var message: String?

    var body: some View {
        let rating = store.rating(for: place)
        let status = store.checkInStatus(for: place)

        List {
            Section {
                LabeledContent("Category", value: place.category)
                LabeledContent("Town", value: place.town)
                if let distance = location.distanceText(to: place) {
                    LabeledContent("Distance", value: distance)
                }
                NavigationLink {
                    DirectionsView(place: place)
                } label: {
                    Label("Walking directions", systemImage: "figure.walk")
                }
            }

            Section("Your visit") {
                if let rating {
                    HStack {
                        VerdictBadge(verdict: rating.verdict, stars: rating.stars)
                        Spacer()
                        Text(rating.date, format: .dateTime.month().day().year())
                            .foregroundStyle(.secondary)
                    }
                    if let photo = store.dishPhoto(for: rating) {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    Text("Not rated yet").foregroundStyle(.secondary)
                }
                LabeledContent("Your check-ins", value: "\(store.checkIns(for: place).count)")
            }

            Section {
                if rating == nil {
                    Button {
                        showRate = true
                    } label: {
                        Label("Rate it", systemImage: "fork.knife")
                    }
                }
                Button {
                    do {
                        try store.checkIn(at: place)
                        message = "Checked in at \(place.name)."
                    } catch {
                        message = error.localizedDescription
                    }
                } label: {
                    Label("Check in", systemImage: "mappin.and.ellipse")
                }
                .disabled(status != .allowed)
            } footer: {
                if let hint = status.hint {
                    Text(hint)
                }
            }
        }
        .navigationTitle(place.name)
        .sheet(isPresented: $showRate) {
            RateView(place: place)
        }
        .alert(message ?? "", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }
}
