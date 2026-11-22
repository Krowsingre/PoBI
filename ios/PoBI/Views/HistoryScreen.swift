import SwiftUI

struct HistoryScreen: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, liked, disliked
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .liked: return "Plate It"
            case .disliked: return "Break It"
            }
        }
    }

    @EnvironmentObject private var store: GameStore
    @State private var filter: Filter = .all

    /// Your ratings, newest first, or only the places you liked or disliked (strongest first).
    private var shownRatings: [Rating] {
        switch filter {
        case .all:
            return store.ratings.sorted { $0.date > $1.date }
        case .liked:
            return store.ratings.filter { $0.verdict == .plateIt }
                .sorted { ($0.stars, $0.date) > ($1.stars, $1.date) }
        case .disliked:
            return store.ratings.filter { $0.verdict == .breakIt }
                .sorted { ($0.stars, $0.date) > ($1.stars, $1.date) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.ratings.isEmpty {
                    Section {
                        Picker("Show", selection: $filter) {
                            ForEach(Filter.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section {
                        if shownRatings.isEmpty {
                            Text(filter == .liked ? "No Plate It ratings yet." : "No Break It ratings yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(shownRatings) { rating in
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
                    } header: {
                        Text(filter == .all ? "Ratings (\(shownRatings.count))"
                             : "\(filter.title) (\(shownRatings.count))")
                    }
                }
                if filter == .all && !store.checkIns.isEmpty {
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
