import Foundation
import UIKit

/// Local game state for the first test builds. The real rules (ownership,
/// takeovers, Counterplate) run on the server; this only enforces the
/// player's own limits: one original rating per place, one check-in a day.
@MainActor
final class GameStore: ObservableObject {
    @Published var team: Team? {
        didSet { save() }
    }
    @Published private(set) var ratings: [Rating] = []
    @Published private(set) var checkIns: [CheckIn] = []

    let places: [Place] = SampleData.places

    /// Every game day, week and month runs on New Jersey time.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }()

    private static let storageKey = "pobi.state.v1"

    private struct Saved: Codable {
        var team: Team?
        var ratings: [Rating]
        var checkIns: [CheckIn]
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            team = saved.team
            ratings = saved.ratings
            checkIns = saved.checkIns
        }
    }

    // MARK: Queries

    func place(id: String) -> Place? {
        places.first { $0.id == id }
    }

    func rating(for place: Place) -> Rating? {
        ratings.first { $0.placeID == place.id }
    }

    func checkIns(for place: Place) -> [CheckIn] {
        checkIns.filter { $0.placeID == place.id }
    }

    func checkInStatus(for place: Place, now: Date = .now) -> CheckInStatus {
        guard rating(for: place) != nil else { return .needsRating }
        let today = checkIns(for: place).contains { Self.calendar.isDate($0.date, inSameDayAs: now) }
        return today ? .alreadyToday : .allowed
    }

    // MARK: Actions

    func rate(_ place: Place, verdict: Verdict, stars: Int, dishPhoto: UIImage?) throws {
        guard rating(for: place) == nil else { throw GameError.alreadyRated }
        let rating = Rating(id: UUID(), placeID: place.id, verdict: verdict, stars: min(max(stars, 1), 3), date: .now)
        if let dishPhoto, let data = dishPhoto.jpegData(compressionQuality: 0.7) {
            try? FileManager.default.createDirectory(at: Self.photosDirectory, withIntermediateDirectories: true)
            try? data.write(to: Self.photoURL(for: rating))
        }
        ratings.append(rating)
        save()
    }

    func checkIn(at place: Place) throws {
        switch checkInStatus(for: place) {
        case .needsRating: throw GameError.notRated
        case .alreadyToday: throw GameError.alreadyCheckedInToday
        case .allowed: break
        }
        checkIns.append(CheckIn(id: UUID(), placeID: place.id, date: .now))
        save()
    }

    func reset() {
        ratings = []
        checkIns = []
        try? FileManager.default.removeItem(at: Self.photosDirectory)
        team = nil
    }

    // MARK: Photos

    static var photosDirectory: URL {
        URL.documentsDirectory.appending(path: "dish-photos", directoryHint: .isDirectory)
    }

    static func photoURL(for rating: Rating) -> URL {
        photosDirectory.appending(path: "\(rating.id.uuidString).jpg")
    }

    func dishPhoto(for rating: Rating) -> UIImage? {
        UIImage(contentsOfFile: Self.photoURL(for: rating).path(percentEncoded: false))
    }

    // MARK: Storage

    private func save() {
        let saved = Saved(team: team, ratings: ratings, checkIns: checkIns)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

enum ImageResizer {
    /// Shrinks a photo so its longest side is at most `maxSide` points (about 150 KB as JPEG).
    static func downscale(_ image: UIImage, maxSide: CGFloat = 1080) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
