import SwiftUI

struct ProfileScreen: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var allergies: AllergyStore
    @EnvironmentObject private var location: LocationManager
    @State private var confirmReset = false

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
                Section {
                    Text("This is an early test build. Your ratings and check-ins stay on this phone. Team ownership, takeovers and Counterplate arrive with the game server.")
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
            .confirmationDialog("Delete your ratings, check-ins and team choice on this phone? Your allergy list is kept.", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { store.reset() }
            }
        }
    }
}
