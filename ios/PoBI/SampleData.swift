import Foundation

/// Made-up sample places across New Jersey, used until the real catalogue
/// (Overture Maps, D8) is loaded from the server. None of these are real businesses.
enum SampleData {
    static let places: [Place] = [
        Place(id: "s01", name: "Sample Diner", category: "Diner", town: "Hoboken", latitude: 40.7440, longitude: -74.0324),
        Place(id: "s02", name: "Sample Bubble Tea", category: "Bubble tea", town: "Jersey City", latitude: 40.7178, longitude: -74.0431),
        Place(id: "s03", name: "Sample Pizzeria", category: "Pizza", town: "Newark", latitude: 40.7357, longitude: -74.1724),
        Place(id: "s04", name: "Sample Café", category: "Café", town: "Montclair", latitude: 40.8259, longitude: -74.2090),
        Place(id: "s05", name: "Sample Brewery", category: "Brewery", town: "Morristown", latitude: 40.7968, longitude: -74.4815),
        Place(id: "s06", name: "Sample Ramen", category: "Ramen", town: "New Brunswick", latitude: 40.4862, longitude: -74.4518),
        Place(id: "s07", name: "Sample Bakery", category: "Bakery", town: "Princeton", latitude: 40.3573, longitude: -74.6672),
        Place(id: "s08", name: "Sample Taqueria", category: "Mexican", town: "Trenton", latitude: 40.2206, longitude: -74.7597),
        Place(id: "s09", name: "Sample Boardwalk Bar", category: "Bar", town: "Asbury Park", latitude: 40.2204, longitude: -74.0121),
        Place(id: "s10", name: "Sample Indian Tea House", category: "Indian tea", town: "Edison", latitude: 40.5187, longitude: -74.4121),
        Place(id: "s11", name: "Sample Seafood Shack", category: "Seafood", town: "Cape May", latitude: 38.9351, longitude: -74.9060),
        Place(id: "s12", name: "Sample Bistro", category: "Restaurant", town: "Collingswood", latitude: 39.9182, longitude: -75.0713),
    ]
}
