import SwiftUI

@main
struct PoBIApp: App {
    @StateObject private var store = GameStore()
    @StateObject private var location = LocationManager()
    @StateObject private var allergies = AllergyStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(location)
                .environmentObject(allergies)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.team == nil {
                TeamPickerView()
            } else {
                TabView {
                    MapScreen()
                        .tabItem { Label("Map", systemImage: "map") }
                    PlacesScreen()
                        .tabItem { Label("Places", systemImage: "list.bullet") }
                    HistoryScreen()
                        .tabItem { Label("History", systemImage: "clock") }
                    ProfileScreen()
                        .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                }
            }
        }
        .onAppear { location.start() }
        // A receipt shared from Mail, Files, a delivery app or a screenshot.
        .onOpenURL { url in
            if url.isFileURL { store.receiveSharedReceipt(url) }
        }
        .sheet(isPresented: Binding(
            get: { store.sharedReceipt != nil && store.team != nil },
            set: { if !$0 { store.clearSharedReceipt() } }
        )) {
            if let url = store.sharedReceipt {
                SharedReceiptView(url: url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                location.start()
                Task { await store.sync() }
            }
        }
    }
}
