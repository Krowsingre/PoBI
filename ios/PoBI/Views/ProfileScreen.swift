import SwiftUI

struct ProfileScreen: View {
    @EnvironmentObject private var store: GameStore
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
                Section("Your stats") {
                    LabeledContent("Places rated", value: "\(store.ratings.count)")
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
                Section {
                    Button("Reset test data", role: .destructive) {
                        confirmReset = true
                    }
                }
            }
            .navigationTitle("Profile")
            .confirmationDialog("Delete your ratings, check-ins and team choice on this phone?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { store.reset() }
            }
        }
    }
}
