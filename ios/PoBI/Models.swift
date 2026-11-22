import CoreLocation
import Foundation
import SwiftUI

/// Placeholder team identities. Names and colors are embre's call (open item 31.1).
enum Team: String, Codable, CaseIterable, Identifiable {
    case team1, team2, team3

    var id: String { rawValue }

    var name: String {
        switch self {
        case .team1: return "Team 1"
        case .team2: return "Team 2"
        case .team3: return "Team 3"
        }
    }

    var color: Color {
        switch self {
        case .team1: return .orange
        case .team2: return .teal
        case .team3: return .purple
        }
    }
}

struct Place: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let category: String
    let town: String
    let latitude: Double
    let longitude: Double
    /// Street address, phone (10 digits) and chain brand from Overture. Any may be empty.
    var address: String = ""
    var phone: String = ""
    var brand: String = ""

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

/// Plate It / Break It, each with one to three stars of intensity.
/// Three Break It stars is the strongest negative, never a good rating.
enum Verdict: String, Codable, CaseIterable, Identifiable {
    case plateIt, breakIt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plateIt: return "Plate It"
        case .breakIt: return "Break It"
        }
    }

    var symbol: String {
        switch self {
        case .plateIt: return "hand.thumbsup.fill"
        case .breakIt: return "hand.thumbsdown.fill"
        }
    }

    var color: Color {
        switch self {
        case .plateIt: return .green
        case .breakIt: return .red
        }
    }

    func meaning(stars: Int) -> String {
        switch (self, stars) {
        case (.plateIt, 1): return "Mildly positive"
        case (.plateIt, 2): return "Positive"
        case (.plateIt, _): return "Extremely positive"
        case (.breakIt, 1): return "Mildly negative"
        case (.breakIt, 2): return "Negative"
        case (.breakIt, _): return "Extremely negative"
        }
    }
}

struct Rating: Identifiable, Codable, Hashable {
    let id: UUID
    let placeID: String
    let verdict: Verdict
    let stars: Int
    let date: Date
    /// True when the place didn't allow food photos and the photo shows the storefront instead (D16).
    var storefrontPhoto: Bool? = nil
}

/// A food or storefront photo taken at the place, kept so the rating can be finished later (D17).
struct PhotoDraft: Codable, Hashable {
    let placeID: String
    let takenAt: Date
    let storefront: Bool
    /// Distance from the place's pin when the photo was taken, in metres.
    let distance: Double
}

struct CheckIn: Identifiable, Codable, Hashable {
    let id: UUID
    let placeID: String
    let date: Date
}

enum CheckInStatus: Equatable {
    case allowed
    case needsRating
    case alreadyToday
    /// Location is off or not known yet.
    case noLocation
    /// The phone's GPS fix is too rough to tell whether you're at the place.
    case roughLocation
    /// You're farther than the check-in reach. Carries the distance in metres.
    case tooFar(Int)

    var hint: String? {
        switch self {
        case .allowed: return nil
        case .needsRating: return "Rate this place first. After that you can check in once a day."
        case .alreadyToday: return "You've checked in here today. Come back tomorrow."
        case .noLocation: return "Turn on location. You need to be at the place."
        case .roughLocation: return "Waiting for a better GPS signal. Step outside or wait a moment."
        case .tooFar(let meters):
            let away = Measurement(value: Double(meters), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
            return "You're \(away) away. Check in when you're at the place, within \(GameStore.checkInReachText)."
        }
    }
}

enum GameError: LocalizedError {
    case alreadyRated
    case notRated
    case alreadyCheckedInToday
    case missingPhotos
    case notHere
    case photoNotAtPlace

    var errorDescription: String? {
        switch self {
        case .alreadyRated: return "You've already rated this place."
        case .notRated: return "Rate this place before checking in."
        case .alreadyCheckedInToday: return "You've already checked in here today."
        case .missingPhotos: return "Take a receipt photo and a food or storefront photo."
        case .notHere: return "You need to be at the place to check in."
        case .photoNotAtPlace: return "Take this photo at the place, within \(GameStore.checkInReachText)."
        }
    }
}
