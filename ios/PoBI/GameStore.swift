import CoreLocation
import Foundation
import UIKit

/// Local game state for the first test builds. The real rules (ownership,
/// takeovers, Counterplate) run on the server; this only enforces the
/// player's own limits: one original rating per place, one check-in a day.
@MainActor
final class GameStore: ObservableObject {
    @Published var team: Team? {
        didSet {
            save()
            Task { await sync() }
        }
    }
    @Published private(set) var ratings: [Rating] = []
    @Published private(set) var checkIns: [CheckIn] = []
    /// Food or storefront photos taken at a place and not yet used in a rating, by place ID.
    @Published private(set) var drafts: [String: PhotoDraft] = [:]

    /// The bundled New Jersey catalogue. It loads in the background at launch.
    @Published private(set) var catalog: PlaceCatalog = .empty
    @Published private(set) var catalogLoaded = false

    /// Ratings and check-ins the server has accepted (or refused for good), by ID.
    @Published private(set) var synced: Set<UUID> = []
    @Published private(set) var syncState: SyncState = ServerClient.shared.isConfigured ? .idle : .notConfigured
    /// Check-ins the server refused, with its reason (for example, too far from the place).
    @Published private(set) var refused: [UUID: String] = [:]
    private var syncing = false
    private var syncAgain = false
    /// Goes up on "Reset test data", so a sync that started before it drops its results.
    private var accountGeneration = 0
    /// The server account that `synced` refers to.
    private var syncedPlayerID: String?

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
        var synced: Set<UUID>?
        var refused: [UUID: String]?
        var syncedPlayerID: String?
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            team = saved.team
            ratings = saved.ratings
            checkIns = saved.checkIns
            drafts = saved.drafts ?? [:]
            synced = saved.synced ?? []
            refused = saved.refused ?? [:]
            syncedPlayerID = saved.syncedPlayerID
        }
        dropExpiredDrafts()
        Task {
            let catalog = await Task.detached(priority: .userInitiated) { PlaceCatalog.loadBundled() }.value
            self.catalog = catalog
            self.catalogLoaded = true
            await self.sync()
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

    /// Saves a rating. Works from anywhere within 7 days of the visit.
    /// - Normally it uses the photo taken at the place (D17) and a receipt the app could read.
    /// - `typedReceipt`: the app couldn't read the receipt, so the player typed it in (D18).
    /// - `withoutPhoto`: the player left without taking the food photo (D19).
    /// Either makes the rating pending, and the receipt photo is kept for review.
    func rate(
        _ place: Place, verdict: Verdict, stars: Int,
        receiptPhoto: UIImage? = nil, typedReceipt: TypedReceipt? = nil, withoutPhoto: Bool = false
    ) throws {
        guard rating(for: place) == nil else { throw GameError.alreadyRated }
        var reasons: [PendingReason] = []
        if typedReceipt != nil { reasons.append(.typedReceipt) }
        var photoData: Data?
        var storefront = false
        if withoutPhoto {
            reasons.append(.noFoodPhoto)
        } else {
            guard let draft = draft(for: place), let photo = draftPhoto(for: place),
                  let data = photo.jpegData(compressionQuality: 0.7) else { throw GameError.missingPhotos }
            photoData = data
            storefront = draft.storefront
        }
        // A pending rating keeps its receipt photo so it can be reviewed.
        var receiptData: Data?
        if !reasons.isEmpty {
            guard let receiptPhoto,
                  let data = ImageResizer.downscale(receiptPhoto, maxSide: 1600).jpegData(compressionQuality: 0.7)
            else { throw GameError.missingReceipt }
            receiptData = data
        }
        let rating = Rating(
            id: UUID(), placeID: place.id, verdict: verdict, stars: min(max(stars, 1), 3), date: .now,
            storefrontPhoto: storefront ? true : nil,
            pending: reasons.isEmpty ? nil : reasons,
            typedReceipt: typedReceipt
        )
        if let photoData {
            try FileManager.default.createDirectory(at: Self.photosDirectory, withIntermediateDirectories: true)
            try photoData.write(to: Self.photoURL(for: rating))
        }
        if let receiptData {
            try FileManager.default.createDirectory(at: Self.receiptsDirectory, withIntermediateDirectories: true)
            try receiptData.write(to: Self.receiptURL(for: rating))
        }
        ratings.append(rating)
        if photoData != nil {
            discardDraft(for: place)
        } else {
            save()
        }
        Task { await sync() }
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
        let now = Date.now
        checkIns.append(CheckIn(
            id: UUID(), placeID: place.id, date: now,
            latitude: here?.coordinate.latitude, longitude: here?.coordinate.longitude,
            accuracy: here?.horizontalAccuracy
        ))
        // Coming back within 30 days makes up for a missing food photo (D19).
        if let index = ratings.firstIndex(where: { $0.placeID == place.id }),
           var reasons = ratings[index].pending, reasons.contains(.noFoodPhoto),
           now < ratings[index].revisitDeadline {
            reasons.removeAll { $0 == .noFoodPhoto }
            ratings[index].pending = reasons.isEmpty ? nil : reasons
        }
        save()
        Task { await sync() }
    }

    func reset() {
        ratings = []
        checkIns = []
        drafts = [:]
        synced = []
        refused = [:]
        syncedPlayerID = nil
        accountGeneration += 1
        syncState = ServerClient.shared.isConfigured ? .idle : .notConfigured
        // A fresh guest account, so the server's copy of the old ratings doesn't block re-rating.
        Task { await ServerClient.shared.signOut() }
        try? FileManager.default.removeItem(at: Self.photosDirectory)
        try? FileManager.default.removeItem(at: Self.draftsDirectory)
        try? FileManager.default.removeItem(at: Self.receiptsDirectory)
        team = nil
    }

    // MARK: Game server

    var unsyncedCount: Int {
        ratings.filter { !synced.contains($0.id) }.count + checkIns.filter { !synced.contains($0.id) }.count
    }

    private static let dayFormat: Date.ISO8601FormatStyle = {
        var style = Date.ISO8601FormatStyle(timeZone: calendar.timeZone)
        style = style.year().month().day()
        return style
    }()

    /// Sends the player's team, ratings and check-ins the server doesn't have yet.
    /// Safe to call often: a call made during a sync makes that sync run once more.
    func sync() async {
        guard ServerClient.shared.isConfigured, team != nil, catalogLoaded else { return }
        guard !syncing else {
            syncAgain = true
            return
        }
        syncing = true
        syncState = .syncing
        defer { syncing = false }
        repeat {
            syncAgain = false
            await syncOnce()
        } while syncAgain && syncState != .notConfigured
    }

    private func syncOnce() async {
        let server = ServerClient.shared
        let generation = accountGeneration
        do {
            let playerID = try await server.registerPlayer(team: team)
            guard generation == accountGeneration else { return }
            if playerID != syncedPlayerID {
                // A different server account (first sync, or the old one was lost):
                // everything has to go to this one.
                synced = []
                refused = [:]
                syncedPlayerID = playerID
                save()
            }
            // Ratings first: the server only accepts a check-in at a place you've rated.
            // Re-read the list each time, so ratings added during the sync go too.
            while let rating = ratings.first(where: { !synced.contains($0.id) && place(id: $0.placeID) != nil }),
                  let place = place(id: rating.placeID) {
                try await server.upload(ServerClient.RatingUpload(
                    id: rating.id, place_id: place.id,
                    latitude: place.latitude, longitude: place.longitude,
                    verdict: rating.verdict.rawValue, stars: rating.stars,
                    storefront_photo: rating.storefrontPhoto ?? false,
                    pending: (rating.pending ?? []).map(\.rawValue),
                    typed_business: rating.typedReceipt?.business,
                    typed_date: rating.typedReceipt.map { $0.date.formatted(Self.dayFormat) }
                ))
                guard generation == accountGeneration else { return }
                synced.insert(rating.id)
                save()
            }
            let sentRatings = Set(ratings.filter { synced.contains($0.id) }.map(\.placeID))
            for checkIn in checkIns where !synced.contains(checkIn.id) {
                // Wait for the place's rating to reach the server first.
                guard sentRatings.contains(checkIn.placeID) else { continue }
                guard let latitude = checkIn.latitude, let longitude = checkIn.longitude,
                      let accuracy = checkIn.accuracy else {
                    // Made before this build recorded locations; the server can't check it.
                    synced.insert(checkIn.id)
                    continue
                }
                do {
                    try await server.upload(ServerClient.CheckInUpload(
                        id: checkIn.id, place_id: checkIn.placeID,
                        latitude: latitude, longitude: longitude, accuracy: accuracy
                    ))
                } catch ServerClient.ServerError.refused(let reason) {
                    guard generation == accountGeneration else { return }
                    refused[checkIn.id] = reason
                }
                guard generation == accountGeneration else { return }
                synced.insert(checkIn.id)
                save()
            }
            syncState = .synced(.now)
        } catch ServerClient.ServerError.accountReset {
            return
        } catch {
            guard generation == accountGeneration else { return }
            save()
            syncState = .failed(error.localizedDescription)
        }
    }

    // MARK: Photos

    static var photosDirectory: URL {
        URL.documentsDirectory.appending(path: "dish-photos", directoryHint: .isDirectory)
    }

    static var draftsDirectory: URL {
        URL.documentsDirectory.appending(path: "photo-drafts", directoryHint: .isDirectory)
    }

    /// Receipt photos kept only for pending ratings, until they're reviewed.
    static var receiptsDirectory: URL {
        URL.documentsDirectory.appending(path: "receipts-for-review", directoryHint: .isDirectory)
    }

    static func receiptURL(for rating: Rating) -> URL {
        receiptsDirectory.appending(path: "\(rating.id.uuidString).jpg")
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
        let saved = Saved(team: team, ratings: ratings, checkIns: checkIns, drafts: drafts,
                          synced: synced, refused: refused, syncedPlayerID: syncedPlayerID)
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
