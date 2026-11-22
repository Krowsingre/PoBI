import SwiftUI

struct HistoryScreen: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        NavigationStack {
            List {
                if !store.ratings.isEmpty {
                    Section("Ratings") {
                        ForEach(store.ratings.sorted { $0.date > $1.date }) { rating in
                            if let place = store.place(id: rating.placeID) {
                                NavigationLink(value: place) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(place.name).font(.headline)
                                            Text(rating.date, format: .dateTime.month().day())
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if rating.isPending {
                                                Label("Pending", systemImage: "hourglass")
                                                    .font(.caption)
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        Spacer()
                                        VerdictBadge(verdict: rating.verdict, stars: rating.stars, compact: true)
                                    }
                                }
                            }
                        }
                    }
                }
                if !store.checkIns.isEmpty {
                    Section("Check-ins") {
                        ForEach(store.checkIns.sorted { $0.date > $1.date }) { checkIn in
                            HStack {
                                Text(store.place(id: checkIn.placeID)?.name ?? "Unknown place")
                                Spacer()
                                Text(checkIn.date, format: .dateTime.month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if store.ratings.isEmpty && store.checkIns.isEmpty {
                    ContentUnavailableView(
                        "No visits yet",
                        systemImage: "fork.knife",
                        description: Text("Rate a place to start. After that you can check in there once a day.")
                    )
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: Place.self) { place in
                PlaceDetailView(place: place)
            }
        }
    }
}
