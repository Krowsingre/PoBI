import CryptoKit
import DeviceCheck
import Foundation
import Security

/// Talks to the game server (Supabase) over its REST API. Players start as guest
/// (anonymous) accounts, and can link Sign in with Apple to keep their progress.
///
/// The server address and public key come from `server.json`, which CI writes from
/// the repository's secrets. Without it (local builds), the app stays offline.
actor ServerClient {
    struct Config: Decodable {
        let url: URL
        let anonKey: String
    }

    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        let userID: String
        /// False once the account is signed in with Apple. Nil on sessions saved by older builds (guests).
        var isAnonymous: Bool? = nil
    }

    enum ServerError: LocalizedError {
        case notConfigured
        case http(Int, String)
        /// The server's rules refused the request (for example, too far away to check in).
        case refused(String)
        /// The account was reset while this request was running; its result is dropped.
        case accountReset
        /// The server requires a verified app (App Attest). The upload is kept and retried.
        case needsUpdate
        /// The Apple sign-in ran out and couldn't be renewed. Nothing is sent until the player signs in again.
        case signInAgain

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "This build isn't connected to the game server."
            case .http(let code, _): return "The game server answered with an error (\(code))."
            case .refused(let message): return message
            case .accountReset: return "The account was reset."
            case .needsUpdate: return "Update Plate or Break It to keep sending your visits."
            case .signInAgain: return "Sign in with Apple again on the Profile tab to keep sending your visits."
            }
        }
    }

    static let shared = ServerClient(config: ServerClient.loadConfig())

    let config: Config?
    private var session: Session?
    /// Goes up on every sign-out, so answers to requests started before it are ignored.
    private var generation = 0

    init(config: Config?) {
        self.config = config
        self.session = Keychain.load()
    }

    nonisolated var isConfigured: Bool { config != nil }

    static func loadConfig() -> Config? {
        guard let url = Bundle.main.url(forResource: "server", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    // MARK: Sign-in

    private struct AuthResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User
        struct User: Decodable {
            let id: String
            let is_anonymous: Bool?
        }
    }

    /// Set when an Apple account's sign-in can't be renewed, so the app doesn't quietly
    /// start a new guest account and leave the player's progress behind.
    private static let lostSignInKey = "pobi.appleSignInLost"
    private var appleSignInLost: Bool {
        get { UserDefaults.standard.bool(forKey: Self.lostSignInKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lostSignInKey) }
    }

    /// Returns a valid session, signing in as a guest or refreshing the token when needed.
    private func validSession() async throws -> Session {
        guard config != nil else { throw ServerError.notConfigured }
        if let session, session.expiresAt.timeIntervalSinceNow > 60 { return session }
        if appleSignInLost { throw ServerError.signInAgain }
        let started = generation
        if let session {
            do {
                return try store(await auth(path: "token?grant_type=refresh_token",
                                            body: ["refresh_token": session.refreshToken]), started: started)
            } catch ServerError.http(let code, _) where (400..<500).contains(code) {
                guard started == generation else { throw ServerError.accountReset }
                if session.isAnonymous == false {
                    // An Apple account: wait for the player to sign in again rather than start over.
                    self.session = nil
                    Keychain.delete()
                    appleSignInLost = true
                    throw ServerError.signInAgain
                }
                // A guest whose refresh token is no longer valid. A new guest account follows below;
                // GameStore notices the new player ID and re-sends everything to it.
            }
        }
        return try store(await auth(path: "signup", body: [String: String]()), started: started)
    }

    private func auth<Body: Encodable>(path: String, body: Body, bearer: String? = nil) async throws -> AuthResponse {
        guard let config else { throw ServerError.notConfigured }
        var request = URLRequest(url: URL(string: "auth/v1/\(path)", relativeTo: config.url)!)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    private func store(_ auth: AuthResponse, started: Int) throws -> Session {
        // A sign-out happened while this request was out: don't bring the old account back.
        guard started == generation else { throw ServerError.accountReset }
        let session = Session(
            accessToken: auth.access_token, refreshToken: auth.refresh_token,
            expiresAt: Date.now.addingTimeInterval(auth.expires_in), userID: auth.user.id,
            isAnonymous: auth.user.is_anonymous ?? true
        )
        self.session = session
        Keychain.save(session)
        return session
    }

    /// Forgets this phone's account (used by "Reset test data" and after deleting the account).
    /// The next request starts a new guest account.
    func signOut() {
        generation += 1
        session = nil
        Keychain.delete()
        appleSignInLost = false
        AttestKeyStore.delete()
        attestStatus = .notChecked
        attestRetryAfter = nil
    }

    // MARK: Sign in with Apple

    /// How this phone is signed in.
    enum Account: Equatable {
        case guest
        case apple
        /// Signed in with Apple, but the sign-in ran out: sign in again to carry on.
        case appleSignInLost
    }

    func account() -> Account {
        if appleSignInLost { return .appleSignInLost }
        return session?.isAnonymous == false ? .apple : .guest
    }

    private struct IDTokenBody: Encodable {
        let provider = "apple"
        let id_token: String
        let nonce: String
        var link_identity: Bool? = nil
    }

    /// Adds the Apple ID to the current guest account, so everything on it is kept.
    /// Returns false when that can't be done: the Apple ID already has its own account,
    /// or there's no guest account to add it to.
    func linkApple(idToken: String, nonce: String) async throws -> Bool {
        guard !appleSignInLost else { return false }
        let started = generation
        let current = try await validSession()
        guard current.isAnonymous != false else { return false }
        do {
            let linked = try await auth(path: "token?grant_type=id_token",
                                        body: IDTokenBody(id_token: idToken, nonce: nonce, link_identity: true),
                                        bearer: current.accessToken)
            guard linked.user.id == current.userID else {
                // Not expected, but never mix two accounts' data.
                throw ServerError.http(409, "linked to a different account")
            }
            var session = try store(linked, started: started)
            if session.isAnonymous != false {
                session.isAnonymous = false
                self.session = session
                Keychain.save(session)
            }
            return true
        } catch ServerError.http(let code, let text)
            where code == 422 && (text.contains("identity_already_exists") || text.contains("email_exists")) {
            return false
        }
    }

    /// Signs in to the Apple ID's own account and reads its saved progress. Only once both have
    /// worked does the phone leave its current account, so a failure leaves everything as it was.
    func signInWithApple(idToken: String, nonce: String) async throws -> (playerID: String, progress: SavedProgress) {
        let started = generation
        let answer = try await auth(path: "token?grant_type=id_token", body: IDTokenBody(id_token: idToken, nonce: nonce))
        let next = Session(
            accessToken: answer.access_token, refreshToken: answer.refresh_token,
            expiresAt: Date.now.addingTimeInterval(answer.expires_in), userID: answer.user.id, isAnonymous: false
        )
        let progress = try await savedProgress(as: next)
        guard started == generation else { throw ServerError.accountReset }
        // Now switch: requests still running for the old account are dropped.
        generation += 1
        session = next
        Keychain.save(next)
        appleSignInLost = false
        if AttestKeyStore.load()?.playerID != next.userID {
            AttestKeyStore.delete()
            attestStatus = .notChecked
            attestRetryAfter = nil
        }
        return (next.userID, progress)
    }

    /// Deletes the account on the server: ratings, check-ins, friends and receipt photos.
    /// Then this phone starts over as a new guest.
    func deleteAccount() async throws {
        guard let config else { throw ServerError.notConfigured }
        let session = try await validSession()
        var request = URLRequest(url: URL(string: "functions/v1/account", relativeTo: config.url)!)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["action": "delete"])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        signOut()
    }

    // MARK: Restoring an account on this phone

    struct SavedRating: Decodable {
        let id: UUID
        let place_id: String
        let verdict: String
        let stars: Int
        let rated_at: String
        let storefront_photo: Bool
        let pending: [String]
        let rejected: Bool
        let typed_business: String?
        let typed_date: String?
        let receipt_printed_at: String?
        let receipt_number: String?
        let receipt_date: String?
        let delivery: Bool
    }

    struct SavedCheckIn: Decodable {
        let id: UUID
        let place_id: String
        let checked_at: String
        let latitude: Double
        let longitude: Double
        let accuracy: Double
    }

    /// Everything the server has for this account: team, ratings and check-ins.
    struct SavedProgress {
        let team: String?
        let ratings: [SavedRating]
        let checkIns: [SavedCheckIn]
        var isEmpty: Bool { team == nil && ratings.isEmpty && checkIns.isEmpty }
    }

    /// Everything the server has for an account: team, ratings and check-ins.
    private func savedProgress(as session: Session) async throws -> SavedProgress {
        struct Player: Decodable { let team: String? }
        let players: [Player] = try await get("players?select=team", as: session)
        let ratings: [SavedRating] = try await get(
            "ratings?select=id,place_id,verdict,stars,rated_at,storefront_photo,pending,rejected,typed_business,"
            + "typed_date,receipt_printed_at,receipt_number,receipt_date,delivery&order=rated_at", as: session
        )
        let checkIns: [SavedCheckIn] = try await get(
            "check_ins?select=id,place_id,checked_at,latitude,longitude,accuracy&order=checked_at", as: session
        )
        return SavedProgress(team: players.first?.team, ratings: ratings, checkIns: checkIns)
    }

    // MARK: Data

    /// Creates the player's row if it doesn't exist yet, and sets the team once.
    /// Returns the player's ID on the server.
    @discardableResult
    func registerPlayer(team: Team?) async throws -> String {
        let session = try await validSession()
        try await rest("players", method: "POST", body: ["id": session.userID],
                       prefer: "resolution=ignore-duplicates,return=minimal")
        if let team {
            // The server only lets a team be picked once; later changes are ignored.
            try await rest("players?id=eq.\(session.userID)&team=is.null", method: "PATCH",
                           body: ["team": team.rawValue], prefer: "return=minimal")
        }
        return session.userID
    }

    struct RatingUpload: Encodable {
        let id: UUID
        let place_id: String
        let latitude: Double
        let longitude: Double
        let verdict: String
        let stars: Int
        let storefront_photo: Bool
        let pending: [String]
        let typed_business: String?
        let typed_date: String?
        let receipt_printed_at: Date?
        let receipt_number: String?
        let receipt_date: String?
        let delivery: Bool
    }

    struct RatingStatus: Decodable {
        let id: UUID
        let pending: [String]
        let rejected: Bool
    }

    /// The server's view of these ratings: still pending (and why), or rejected.
    func status(of ids: [UUID]) async throws -> [RatingStatus] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map { $0.uuidString.lowercased() }.joined(separator: ",")
        return try await get("ratings?select=id,pending,rejected&id=in.(\(list))")
    }

    // MARK: Friends and other players' ratings

    struct Profile: Decodable {
        let nickname: String?
        let friend_code: String
    }

    struct Friend: Decodable, Identifiable, Equatable {
        let id: UUID
        let nickname: String?
        let team: String?
        /// friend, incoming (they asked you) or outgoing (you asked them).
        let status: String
        let ratings: Int?

        var name: String { nickname ?? "Player without a nickname" }
    }

    struct FriendRating: Decodable, Identifiable, Equatable {
        let place_id: String
        let verdict: String
        let stars: Int
        let rated_at: String
        var id: String { place_id }
    }

    /// Plate It and Break It counts, and the average score from -3 (all three-star Break It) to +3.
    struct Tally: Decodable, Equatable {
        let plate: Int
        let dislikes: Int
        let score: Double?
        var total: Int { plate + dislikes }

        enum CodingKeys: String, CodingKey {
            case plate, score
            case dislikes = "break"
        }
    }

    struct PlaceRatings: Decodable, Equatable {
        let overall: Tally
        let team: Tally
        let friends: Tally
        let friend_ratings: [FriendPlaceRating]
    }

    struct FriendPlaceRating: Decodable, Identifiable, Equatable {
        let nickname: String
        let team: String?
        let verdict: String
        let stars: Int
        let rated_at: String
        var id: String { nickname + rated_at }
    }

    func myProfile() async throws -> Profile? {
        let rows: [Profile] = try await rpc("my_profile", body: [String: String]())
        return rows.first
    }

    func setNickname(_ name: String) async throws {
        _ = try await rpcData("set_nickname", body: ["name": name])
    }

    /// Returns "requested", "accepted" (they had already asked you) or "already".
    func addFriend(code: String) async throws -> String {
        try await rpc("add_friend", body: ["code": code])
    }

    func answerFriend(_ player: UUID, accept: Bool) async throws {
        struct Body: Encodable { let player: UUID; let accept: Bool }
        _ = try await rpcData("answer_friend", body: Body(player: player, accept: accept))
    }

    func removeFriend(_ player: UUID) async throws {
        _ = try await rpcData("remove_friend", body: ["player": player.uuidString.lowercased()])
    }

    func friends() async throws -> [Friend] {
        try await rpc("friends", body: [String: String]())
    }

    func friendRatings(_ friend: UUID) async throws -> [FriendRating] {
        try await rpc("friend_ratings", body: ["friend": friend.uuidString.lowercased()])
    }

    func placeRatings(_ placeID: String) async throws -> PlaceRatings {
        try await rpc("place_ratings", body: ["place": placeID])
    }

    // MARK: Review (D18): for players listed as reviewers on the server

    struct ReviewItem: Decodable, Identifiable, Equatable {
        let id: UUID
        let place_id: String
        let verdict: String
        let stars: Int
        let rated_at: String
        let pending: [String]
        let typed_business: String?
        let typed_date: String?
        let receipt_printed_at: String?
        let receipt_number: String?
        let receipt_path: String?
        let look_alike_reasons: [String]
    }

    /// This phone's player ID on the server (shown on Profile, used to add a reviewer).
    func playerID() async throws -> String {
        try await validSession().userID
    }

    func isReviewer() async throws -> Bool {
        try await rpc("is_reviewer", body: [String: String]())
    }

    func reviewQueue() async throws -> [ReviewItem] {
        try await rpc("review_queue", body: [String: String]())
    }

    func review(_ rating: UUID, approve: Bool, note: String?) async throws {
        struct Body: Encodable { let rating: UUID; let approve: Bool; let note: String? }
        _ = try await rpcData("review_rating", body: Body(rating: rating, approve: approve, note: note))
    }

    /// Downloads a receipt photo from the private bucket (reviewers only).
    func receiptImage(at path: String) async throws -> Data {
        guard let config else { throw ServerError.notConfigured }
        let session = try await validSession()
        var request = URLRequest(url: URL(string: "storage/v1/object/authenticated/receipts/\(path)", relativeTo: config.url)!)
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return data
    }

    private func rpc<Body: Encodable, T: Decodable>(_ name: String, body: Body) async throws -> T {
        try await JSONDecoder().decode(T.self, from: rpcData(name, body: body))
    }

    private func rpcData<Body: Encodable>(_ name: String, body: Body) async throws -> Data {
        guard let config else { throw ServerError.notConfigured }
        let started = generation
        let session = try await validSession()
        var request = URLRequest(url: URL(string: "rest/v1/rpc/\(name)", relativeTo: config.url)!)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard started == generation else { throw ServerError.accountReset }
        try Self.check(response, data)
        return data
    }

    /// Uploads a receipt photo for review into the player's own private folder.
    func uploadReceipt(_ jpeg: Data, for rating: UUID) async throws {
        guard let config else { throw ServerError.notConfigured }
        let started = generation
        let session = try await validSession()
        let path = "\(session.userID)/\(rating.uuidString.lowercased()).jpg"
        var request = URLRequest(url: URL(string: "storage/v1/object/receipts/\(path)", relativeTo: config.url)!)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        let (data, response) = try await URLSession.shared.data(for: request)
        guard started == generation else { throw ServerError.accountReset }
        // Already there from an earlier try that didn't finish: carry on and mark it uploaded.
        let alreadyThere = (response as? HTTPURLResponse).map {
            $0.statusCode == 409 || ($0.statusCode == 400 && String(decoding: data, as: UTF8.self).contains("Duplicate"))
        } ?? false
        if !alreadyThere { try Self.check(response, data) }
        try await rest("ratings?id=eq.\(rating.uuidString.lowercased())", method: "PATCH",
                       body: ["receipt_photo": true], prefer: "return=minimal")
    }

    struct CheckInUpload: Encodable {
        let id: UUID
        let place_id: String
        let latitude: Double
        let longitude: Double
        let accuracy: Double
    }

    /// Uploads a rating. Uploading the same rating twice is harmless.
    func upload(_ rating: RatingUpload) async throws {
        try await insert("ratings", rating)
    }

    /// Uploads a check-in. The server checks it's within 80 m of the place, once a day.
    func upload(_ checkIn: CheckInUpload) async throws {
        try await insert("check_ins", checkIn)
    }

    /// Sends a rating or check-in, signed with App Attest when this iPhone can.
    /// Without it (simulator, or the check failed), it goes straight to the database,
    /// which accepts it as not attested for as long as the server allows that.
    private func insert<Body: Encodable>(_ table: String, _ body: Body) async throws {
        guard config != nil else { throw ServerError.notConfigured }
        let started = generation
        let session = try await validSession()
        let data = try Self.encoder.encode(body)
        if let keyID = await attestedKey(for: session) {
            do {
                let hash = Data(SHA256.hash(data: data))
                let assertion = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: hash)
                let (answer, response) = try await callFunction([
                    "action": "submit", "table": table, "keyId": keyID,
                    "assertion": assertion.base64EncodedString(),
                    "body": String(decoding: data, as: UTF8.self),
                ], session: session)
                guard started == generation else { throw ServerError.accountReset }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let reply = try? JSONSerialization.jsonObject(with: answer) as? [String: Any]
                let code = reply?["code"] as? String
                if code == "unknown_key" || code == "attest_failed" {
                    // The server doesn't know this key or didn't accept its signature: make a new one next time.
                    forgetAttestKey(reply?["message"] as? String ?? "Not accepted")
                } else if status >= 500 || status == 404 || code == "replayed" {
                    // The signing step is down, not deployed, or tripped over itself: send it directly this time.
                } else {
                    if status == 409 { return }
                    try Self.check(response, answer)
                    attestStatus = .verified
                    return
                }
            } catch let error as DCError {
                // A lost or broken key is replaced next time. Other App Attest errors just skip signing this once.
                if error.code == .invalidKey || error.code == .invalidInput {
                    forgetAttestKey(error.localizedDescription)
                }
            } catch is URLError {
                // Couldn't reach the signing step: try the database directly below.
            }
        }
        // Started before a reset: drop it rather than sending it to the new account.
        guard started == generation else { throw ServerError.accountReset }
        try await rest(table, method: "POST", body: body,
                       prefer: "resolution=ignore-duplicates,return=minimal", conflictIsOK: true)
    }

    // MARK: App Attest

    enum AttestStatus: Equatable {
        case notChecked
        /// This device can't use App Attest (for example, the simulator).
        case unsupported
        case verified
        case failed(String)
    }

    /// Whether this iPhone has proved to the server that it's running the real app.
    private(set) var attestStatus: AttestStatus = .notChecked
    /// After a failed attempt, wait before asking Apple again (it limits how often a phone can attest).
    private var attestRetryAfter: Date?
    private var registering: Task<String, Error>?

    /// The App Attest key for this account, registering a new one with the server if needed.
    private func attestedKey(for session: Session) async -> String? {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            attestStatus = .unsupported
            return nil
        }
        if let saved = AttestKeyStore.load(), saved.playerID == session.userID {
            return saved.keyID
        }
        if let retry = attestRetryAfter, retry > .now { return nil }
        let task = registering ?? Task { try await self.registerAttestKey(session: session) }
        registering = task
        defer { registering = nil }
        do {
            let keyID = try await task.value
            attestStatus = .verified
            return keyID
        } catch {
            attestStatus = .failed(error.localizedDescription)
            attestRetryAfter = Date.now.addingTimeInterval(60 * 60)
            return nil
        }
    }

    private func registerAttestKey(session: Session) async throws -> String {
        struct Challenge: Decodable { let challenge: String }
        let service = DCAppAttestService.shared
        let keyID = try await service.generateKey()
        let (data, response) = try await callFunction(["action": "challenge"], session: session)
        try Self.check(response, data)
        let challenge = try JSONDecoder().decode(Challenge.self, from: data).challenge
        let attestation = try await service.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        let (answer, registered) = try await callFunction([
            "action": "register", "keyId": keyID,
            "attestation": attestation.base64EncodedString(), "challenge": challenge,
        ], session: session)
        try Self.check(registered, answer)
        AttestKeyStore.save(.init(playerID: session.userID, keyID: keyID))
        return keyID
    }

    private func forgetAttestKey(_ reason: String) {
        AttestKeyStore.delete()
        attestStatus = .failed(reason)
        attestRetryAfter = Date.now.addingTimeInterval(60 * 60)
    }

    private func callFunction(_ body: [String: String], session: Session) async throws -> (Data, URLResponse) {
        guard let config else { throw ServerError.notConfigured }
        var request = URLRequest(url: URL(string: "functions/v1/attest", relativeTo: config.url)!)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await URLSession.shared.data(for: request)
    }

    /// An area a team owns, with its hexagon's corners as [latitude, longitude] pairs.
    struct AreaOwner: Decodable, Identifiable, Equatable {
        let area: String
        let team: String
        let boundary: [[Double]]
        var id: String { area }
    }

    struct PlaceOwner: Decodable {
        let place_id: String
        let team: String
    }

    /// Who owns which areas and places, as last worked out by the game runner.
    func owners() async throws -> (areas: [AreaOwner], places: [PlaceOwner]) {
        let areas: [AreaOwner] = try await get("area_owners?select=area,team,boundary")
        let places: [PlaceOwner] = try await get("place_owners?select=place_id,team")
        return (areas, places)
    }

    private func get<T: Decodable>(_ path: String, as fixed: Session? = nil) async throws -> T {
        guard let config else { throw ServerError.notConfigured }
        let started = generation
        let session: Session
        if let fixed { session = fixed } else { session = try await validSession() }
        var request = URLRequest(url: URL(string: "rest/v1/\(path)", relativeTo: config.url)!)
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard started == generation else { throw ServerError.accountReset }
        try Self.check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func rest<Body: Encodable>(_ path: String, method: String, body: Body,
                                       prefer: String, conflictIsOK: Bool = false) async throws {
        guard let config else { throw ServerError.notConfigured }
        let started = generation
        let session = try await validSession()
        var request = URLRequest(url: URL(string: "rest/v1/\(path)", relativeTo: config.url)!)
        request.httpMethod = method
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(prefer, forHTTPHeaderField: "Prefer")
        request.httpBody = try Self.encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard started == generation else { throw ServerError.accountReset }
        if conflictIsOK, (response as? HTTPURLResponse)?.statusCode == 409 { return }
        try Self.check(response, data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerError.http(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data, as: UTF8.self)
            // Rules raised by the database come back as {"code":"P0001","message":"..."}.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["code"] as? String == "P0001", let message = json["message"] as? String {
                throw ServerError.refused(message)
            }
            // 426: the server now requires App Attest and this upload didn't have it. Kept and retried.
            if http.statusCode == 426 { throw ServerError.needsUpdate }
            throw ServerError.http(http.statusCode, text)
        }
    }
}

/// The App Attest key ID for the current account. The key itself never leaves the Secure Enclave.
private enum AttestKeyStore {
    struct Saved: Codable {
        let playerID: String
        let keyID: String
    }

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.krowsingre.pobi.server",
        kSecAttrAccount as String: "attest-key",
    ]

    static func load() -> Saved? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Keeps the guest account's tokens in the iPhone's Keychain.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.krowsingre.pobi.server",
        kSecAttrAccount as String: "session",
    ]

    static func load() -> ServerClient.Session? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ServerClient.Session.self, from: data)
    }

    static func save(_ session: ServerClient.Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
