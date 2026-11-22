import Foundation
import Security

/// Talks to the game server (Supabase) over its REST API. Players start as guest
/// (anonymous) accounts, so there's no sign-up screen yet.
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
    }

    enum ServerError: LocalizedError {
        case notConfigured
        case http(Int, String)
        /// The server's rules refused the request (for example, too far away to check in).
        case refused(String)
        /// The account was reset while this request was running; its result is dropped.
        case accountReset

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "This build isn't connected to the game server."
            case .http(let code, _): return "The game server answered with an error (\(code))."
            case .refused(let message): return message
            case .accountReset: return "The account was reset."
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
        struct User: Decodable { let id: String }
    }

    /// Returns a valid session, signing in as a guest or refreshing the token when needed.
    private func validSession() async throws -> Session {
        guard config != nil else { throw ServerError.notConfigured }
        if let session, session.expiresAt.timeIntervalSinceNow > 60 { return session }
        let started = generation
        if let session {
            do {
                return try store(await auth(path: "token?grant_type=refresh_token",
                                            body: ["refresh_token": session.refreshToken]), started: started)
            } catch ServerError.http(let code, _) where (400..<500).contains(code) {
                // The refresh token is no longer valid. A new guest account follows below;
                // GameStore notices the new player ID and re-sends everything to it.
            }
        }
        return try store(await auth(path: "signup", body: [:]), started: started)
    }

    private func auth(path: String, body: [String: String]) async throws -> AuthResponse {
        guard let config else { throw ServerError.notConfigured }
        var request = URLRequest(url: URL(string: "auth/v1/\(path)", relativeTo: config.url)!)
        request.httpMethod = "POST"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            expiresAt: Date.now.addingTimeInterval(auth.expires_in), userID: auth.user.id
        )
        self.session = session
        Keychain.save(session)
        return session
    }

    /// Forgets this phone's guest account (used by "Reset test data").
    func signOut() {
        generation += 1
        session = nil
        Keychain.delete()
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
        try await rest("ratings", method: "POST", body: rating,
                       prefer: "resolution=ignore-duplicates,return=minimal", conflictIsOK: true)
    }

    /// Uploads a check-in. The server checks it's within 80 m of the place, once a day.
    func upload(_ checkIn: CheckInUpload) async throws {
        try await rest("check_ins", method: "POST", body: checkIn,
                       prefer: "resolution=ignore-duplicates,return=minimal", conflictIsOK: true)
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

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let config else { throw ServerError.notConfigured }
        let started = generation
        let session = try await validSession()
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
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard started == generation else { throw ServerError.accountReset }
        if conflictIsOK, (response as? HTTPURLResponse)?.statusCode == 409 { return }
        try Self.check(response, data)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerError.http(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data, as: UTF8.self)
            // Rules raised by the database come back as {"code":"P0001","message":"..."}.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["code"] as? String == "P0001", let message = json["message"] as? String {
                throw ServerError.refused(message)
            }
            throw ServerError.http(http.statusCode, text)
        }
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
