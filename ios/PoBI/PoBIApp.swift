import SwiftUI

@main
struct PoBIApp: App {
    @StateObject private var store = GameStore()
    @StateObject private var location = LocationManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(location)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var location: LocationManager

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
    }
}
