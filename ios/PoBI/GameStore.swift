import CoreLocation
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
    /// Food or storefront photos taken at a place and not yet used in a rating, by place ID.
    @Published private(set) var drafts: [String: PhotoDraft] = [:]

    /// The bundled New Jersey catalogue. It loads in the background at launch.
    @Published private(set) var catalog: PlaceCatalog = .empty
    @Published private(set) var catalogLoaded = false

    /// Used when the phone's location isn't known yet: central New Jersey.
    static let defaultCenter = CLLocationCoordinate2D(latitude: 40.22, longitude: -74.55)

    /// Every game day, week and month runs on New Jersey time.
    nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }()

    private static let storageKey = "pobi.state.v1"

    private struct Saved: Codable {
        var team: Team?
        var ratings: [Rating]
        var checkIns: [CheckIn]
        var drafts: [String: PhotoDraft]?
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            team = saved.team
            ratings = saved.ratings
            checkIns = saved.checkIns
            drafts = saved.drafts ?? [:]
        }
        dropExpiredDrafts()
        Task {
            let catalog = await Task.detached(priority: .userInitiated) { PlaceCatalog.loadBundled() }.value
            self.catalog = catalog
            self.catalogLoaded = true
        }
    }

    // MARK: Queries

    func place(id: String) -> Place? {
        catalog.place(id: id)
    }

    func rating(for place: Place) -> Rating? {
        ratings.first { $0.placeID == place.id }
    }

    func checkIns(for place: Place) -> [CheckIn] {
        checkIns.filter { $0.placeID == place.id }
    }

    /// You can check in only within this distance of a place's pin, like Pokémon GO (D12).
    nonisolated static let checkInReach: CLLocationDistance = 80
    /// A GPS fix rougher than this can't tell whether you're at the place.
    static let worstUsableAccuracy: CLLocationAccuracy = 100

    nonisolated static var checkInReachText: String {
        Measurement(value: checkInReach, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    func checkInStatus(for place: Place, from here: CLLocation?, now: Date = .now) -> CheckInStatus {
        guard rating(for: place) != nil else { return .needsRating }
        let today = checkIns(for: place).contains { Self.calendar.isDate($0.date, inSameDayAs: now) }
        if today { return .alreadyToday }
        return presence(at: place, from: here, now: now)
    }

    /// Whether you're at the place right now: a fresh, accurate fix within the check-in reach.
    /// Used for check-ins (D12) and for food and storefront photos (D17).
    func presence(at place: Place, from here: CLLocation?, now: Date = .now) -> CheckInStatus {
        // A fix older than two minutes may be from somewhere else (for example, location was turned off after).
        guard let here, now.timeIntervalSince(here.timestamp) <= 120 else { return .noLocation }
        guard here.horizontalAccuracy >= 0, here.horizontalAccuracy <= Self.worstUsableAccuracy else { return .roughLocation }
        let distance = here.distance(from: place.location)
        if distance > Self.checkInReach { return .tooFar(Int(distance.rounded())) }
        return .allowed
    }

    // MARK: Actions

    /// Saves a food or storefront photo taken at the place. It's kept for 7 days so you can
    /// finish the rating after you leave (D17).
    func savePhotoDraft(_ photo: UIImage, for place: Place, storefront: Bool, from here: CLLocation?) throws {
        guard presence(at: place, from: here) == .allowed, let here else { throw GameError.photoNotAtPlace }
        guard let data = photo.jpegData(compressionQuality: 0.7) else { throw GameError.missingPhotos }
        try FileManager.default.createDirectory(at: Self.draftsDirectory, withIntermediateDirectories: true)
        try data.write(to: Self.draftURL(for: place.id))
        drafts[place.id] = PhotoDraft(
            placeID: place.id, takenAt: .now, storefront: storefront,
            distance: here.distance(from: place.location)
        )
        save()
    }

    func draft(for place: Place, now: Date = .now) -> PhotoDraft? {
        guard let draft = drafts[place.id], !isExpired(draft, now: now) else { return nil }
        return draft
    }

    func draftPhoto(for place: Place) -> UIImage? {
        guard draft(for: place) != nil else { return nil }
        return UIImage(contentsOfFile: Self.draftURL(for: place.id).path(percentEncoded: false))
    }

    func discardDraft(for place: Place) {
        drafts[place.id] = nil
        try? FileManager.default.removeItem(at: Self.draftURL(for: place.id))
        save()
    }

    /// Finishes a rating from the photo taken at the place. Works from anywhere within 7 days.
    func rate(_ place: Place, verdict: Verdict, stars: Int) throws {
        guard rating(for: place) == nil else { throw GameError.alreadyRated }
        guard let draft = draft(for: place), let photo = draftPhoto(for: place),
              let data = photo.jpegData(compressionQuality: 0.7) else { throw GameError.missingPhotos }
        let rating = Rating(
            id: UUID(), placeID: place.id, verdict: verdict, stars: min(max(stars, 1), 3), date: .now,
            storefrontPhoto: draft.storefront ? true : nil
        )
        try FileManager.default.createDirectory(at: Self.photosDirectory, withIntermediateDirectories: true)
        try data.write(to: Self.photoURL(for: rating))
        ratings.append(rating)
        discardDraft(for: place)
    }

    private func isExpired(_ draft: PhotoDraft, now: Date) -> Bool {
        let calendar = Self.calendar
        guard let limit = calendar.date(byAdding: .day, value: ReceiptReader.maxAgeDays + 1,
                                        to: calendar.startOfDay(for: draft.takenAt)) else { return true }
        return now >= limit
    }

    private func dropExpiredDrafts() {
        for (placeID, draft) in drafts where isExpired(draft, now: .now) {
            drafts[placeID] = nil
            try? FileManager.default.removeItem(at: Self.draftURL(for: placeID))
        }
        save()
    }

    func checkIn(at place: Place, from here: CLLocation?) throws {
        switch checkInStatus(for: place, from: here) {
        case .needsRating: throw GameError.notRated
        case .alreadyToday: throw GameError.alreadyCheckedInToday
        case .noLocation, .roughLocation, .tooFar: throw GameError.notHere
        case .allowed: break
        }
        checkIns.append(CheckIn(id: UUID(), placeID: place.id, date: .now))
        save()
    }

    func reset() {
        ratings = []
        checkIns = []
        drafts = [:]
        try? FileManager.default.removeItem(at: Self.photosDirectory)
        try? FileManager.default.removeItem(at: Self.draftsDirectory)
        team = nil
    }

    // MARK: Photos

    static var photosDirectory: URL {
        URL.documentsDirectory.appending(path: "dish-photos", directoryHint: .isDirectory)
    }

    static var draftsDirectory: URL {
        URL.documentsDirectory.appending(path: "photo-drafts", directoryHint: .isDirectory)
    }

    static func draftURL(for placeID: String) -> URL {
        draftsDirectory.appending(path: "\(placeID).jpg")
    }

    static func photoURL(for rating: Rating) -> URL {
        photosDirectory.appending(path: "\(rating.id.uuidString).jpg")
    }

    func dishPhoto(for rating: Rating) -> UIImage? {
        UIImage(contentsOfFile: Self.photoURL(for: rating).path(percentEncoded: false))
    }

    // MARK: Storage

    private func save() {
        let saved = Saved(team: team, ratings: ratings, checkIns: checkIns, drafts: drafts)
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
