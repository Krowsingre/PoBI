import SwiftUI

struct ProfileScreen: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var allergies: AllergyStore
    @EnvironmentObject private var location: LocationManager
    @State private var confirmReset = false
    @State private var playerID: String?
    @State private var isReviewer = false

    var body: some View {
        NavigationStack {
            List {
                if let team = store.team {
                    Section("Team") {
                        HStack {
                            Circle().fill(team.color).frame(width: 14, height: 14)
                            Text(team.name)
                        }
                    }
                }
                Section {
                    NavigationLink {
                        AllergiesView()
                    } label: {
                        LabeledContent {
                            Text(allergies.all.isEmpty ? "None added" : allergies.all.joined(separator: ", "))
                                .lineLimit(1)
                        } label: {
                            Label("My allergies", systemImage: "allergens")
                        }
                    }
                } footer: {
                    Text("Kept only on this phone.")
                }
                Section("Your stats") {
                    LabeledContent("Places rated", value: "\(store.ratings.count)")
                    if store.ratings.contains(where: \.isPending) {
                        LabeledContent("Waiting for review or a revisit", value: "\(store.ratings.filter(\.isPending).count)")
                    }
                    LabeledContent("Plate It", value: "\(store.ratings.filter { $0.verdict == .plateIt }.count)")
                    LabeledContent("Break It", value: "\(store.ratings.filter { $0.verdict == .breakIt }.count)")
                    LabeledContent("Check-ins", value: "\(store.checkIns.count)")
                }
                if isReviewer {
                    Section {
                        NavigationLink {
                            ReviewView()
                        } label: {
                            Label("Review receipts", systemImage: "checkmark.seal")
                        }
                    } footer: {
                        Text("You're a reviewer. Approve or reject ratings waiting on a receipt check.")
                    }
                }
                Section {
                    ServerStatusRow()
                    if let playerID {
                        LabeledContent("Player ID") {
                            Text(playerID.prefix(8) + "…").font(.footnote.monospaced())
                        }
                        .contextMenu {
                            Button("Copy player ID") { UIPasteboard.general.string = playerID }
                        }
                    }
                } header: {
                    Text("Game server")
                } footer: {
                    Text("Your ratings and check-ins are sent to the game server so they count for your team. On the map, a coloured hexagon is an area a team won at month end, and a coloured ring on a pin shows which team holds that place through check-ins. Owners update about every 15 minutes.")
                }
                Section {
                    Text("This is an early test build.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Place data: Overture Maps Foundation, under CDLA Permissive 2.0 and the licenses of its sources. Maps and walking routes: Apple Maps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About this build")
                }
                if LocationManager.testingAllowed {
                    Section {
                        if let test = location.testLocation {
                            LabeledContent("Pretending to be at", value: test.name)
                            Button("Use my real location") { location.clearTestLocation() }
                        } else {
                            Text("Using your real location.")
                        }
                    } header: {
                        Text("Testing: fake location")
                    } footer: {
                        Text("Open any place and tap \"Test: pretend I'm here\" to rate, photograph and check in there without going. Only in test builds.")
                    }
                }
                Section {
                    Button("Reset test data", role: .destructive) {
                        confirmReset = true
                    }
                }
            }
            .navigationTitle("Profile")
            .task(id: store.syncState) {
                guard ServerClient.shared.isConfigured, case .synced = store.syncState else { return }
                playerID = try? await ServerClient.shared.playerID()
                isReviewer = (try? await ServerClient.shared.isReviewer()) ?? false
            }
            .confirmationDialog("Delete your ratings, check-ins and team choice on this phone? Your allergy list is kept.", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { store.reset() }
            }
        }
    }
}

private struct ServerStatusRow: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        switch store.syncState {
        case .notConfigured:
            Label("Not connected in this build", systemImage: "icloud.slash")
                .foregroundStyle(.secondary)
        case .idle, .syncing:
            HStack {
                ProgressView()
                Text("Sending your visits…")
            }
        case .synced(let date):
            if store.unsyncedCount == 0 {
                Label("Up to date, \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.icloud")
                    .foregroundStyle(.green)
            } else {
                Label("\(store.unsyncedCount) waiting to send", systemImage: "icloud.and.arrow.up")
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't reach the server", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                Button("Try again") { Task { await store.sync() } }
            }
        }
        if !store.refused.isEmpty {
            Label("The server didn't accept \(store.refused.count) check-in\(store.refused.count == 1 ? "" : "s"): \(store.refused.values.first ?? "")",
                  systemImage: "xmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
