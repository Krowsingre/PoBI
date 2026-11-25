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
    /// Why the rating doesn't count yet. Empty or nil means it counts.
    var pending: [PendingReason]? = nil
    /// What the player typed when the app couldn't read the receipt (D18).
    var typedReceipt: TypedReceipt? = nil
    /// Printed time and order number read off the receipt, for the server's look-alike check (D17).
    var receiptPrintedAt: Date? = nil
    var receiptNumber: String? = nil
    /// The date printed on the receipt, when it could be read.
    var receiptDate: Date? = nil
    /// A reviewer turned this rating down. It never counts.
    var rejected: Bool? = nil

    var isPending: Bool { !(pending ?? []).isEmpty || rejected == true }

    /// How long a check-in can clear a missing food photo (D19).
    static let revisitDays = 30

    /// The last moment a check-in at the place clears a missing food photo.
    var revisitDeadline: Date {
        let calendar = GameStore.calendar
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: Self.revisitDays + 1, to: start) ?? date
    }

    /// One line on what the rating is waiting for, or nil when it counts.
    func pendingText(now: Date = .now) -> String? {
        if rejected == true {
            return "Turned down in review. This rating doesn't count for your team."
        }
        let reasons = pending ?? []
        guard !reasons.isEmpty else { return nil }
        var parts: [String] = []
        if reasons.contains(.lookAlike) {
            parts.append("the receipt looks like part of another player's order, so it needs a review")
        }
        if reasons.contains(.typedReceipt) {
            parts.append("the receipt photo needs a review")
        }
        if reasons.contains(.digitalReceipt) {
            parts.append("the digital receipt needs a review")
        }
        if reasons.contains(.noFoodPhoto) {
            if now < revisitDeadline {
                let day = revisitDeadline.addingTimeInterval(-1).formatted(.dateTime.month().day())
                parts.append("check in here by \(day) (or pass a receipt review) to make up for the missing food photo")
            } else {
                parts.append("the missing food photo needs a receipt review")
            }
        }
        return "Pending: " + parts.joined(separator: ", and ") + ". It doesn't count for your team until then."
    }
}

/// Why a rating is waiting before it counts.
enum PendingReason: String, Codable, Hashable {
    /// The app couldn't read the receipt, so the player typed the details (D18).
    case typedReceipt
    /// The player left without taking the food or storefront photo (D19).
    case noFoodPhoto
    /// The server found another player's receipt from what looks like the same order (D17).
    case lookAlike
    /// The receipt was shared into the app (PDF, email or screenshot), which is easier to fake than paper.
    case digitalReceipt
}

struct TypedReceipt: Codable, Hashable {
    let business: String
    let date: Date
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
    /// Where the phone was, for the server's own 80 m check. Missing on check-ins from older builds.
    var latitude: Double? = nil
    var longitude: Double? = nil
    var accuracy: Double? = nil
}

/// How the phone's ratings and check-ins stand with the game server.
enum SyncState: Equatable {
    /// This build has no server address (local builds).
    case notConfigured
    case idle
    case syncing
    case synced(Date)
    case failed(String)
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
    case missingReceipt

    var errorDescription: String? {
        switch self {
        case .alreadyRated: return "You've already rated this place."
        case .notRated: return "Rate this place before checking in."
        case .alreadyCheckedInToday: return "You've already checked in here today."
        case .missingPhotos: return "Take a receipt photo and a food or storefront photo."
        case .notHere: return "You need to be at the place to check in."
        case .photoNotAtPlace: return "Take this photo at the place, within \(GameStore.checkInReachText)."
        case .missingReceipt: return "Take a photo of the receipt. It's kept for the review."
        }
    }
}
