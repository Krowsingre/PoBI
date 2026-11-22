import SwiftUI

struct PlaceDetailView: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager
    let place: Place

    @State private var showRate = false
    @State private var message: String?

    var body: some View {
        let rating = store.rating(for: place)
        let status = store.checkInStatus(for: place, from: location.location)

        List {
            Section {
                LabeledContent("Category", value: place.category)
                if !place.address.isEmpty {
                    LabeledContent("Address", value: place.address)
                }
                LabeledContent("Town", value: place.town)
                if let owner = store.placeOwners[place.id] {
                    LabeledContent("Held by") {
                        HStack(spacing: 6) {
                            Circle().fill(owner.color).frame(width: 10, height: 10)
                            Text(owner.name)
                        }
                    }
                }
                if let distance = location.distanceText(to: place) {
                    LabeledContent("Distance", value: distance)
                }
                if LocationManager.testingAllowed {
                    Button {
                        location.setTestLocation(at: place)
                    } label: {
                        Label(
                            location.testLocation?.name == place.name ? "Test: pretending you're here" : "Test: pretend I'm here",
                            systemImage: "location.viewfinder"
                        )
                    }
                    .tint(.orange)
                }
                NavigationLink {
                    DirectionsView(place: place)
                } label: {
                    Label("Walking directions", systemImage: "figure.walk")
                }
            }

            AllergyReminder()

            Section("Your visit") {
                if let rating {
                    HStack {
                        VerdictBadge(verdict: rating.verdict, stars: rating.stars)
                        Spacer()
                        Text(rating.date, format: .dateTime.month().day().year())
                            .foregroundStyle(.secondary)
                    }
                    if let pending = rating.pendingText() {
                        Label(pending, systemImage: "hourglass")
                            .font(.footnote)
                            .foregroundStyle(.orange)
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
                        Label(store.draft(for: place) == nil ? "Rate it" : "Finish your rating", systemImage: "fork.knife")
                    }
                }
                Button {
                    do {
                        try store.checkIn(at: place, from: location.location)
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
