import Foundation

/// Reddit application-only OAuth ("installed_client" grant): exchanges a public client ID for a
/// read-only app token — no user login, no secret. Caches the token until it expires.
actor RedditAuth {
    static let shared = RedditAuth()

    private var token: String?
    private var expiry: Date?

    func token(clientID: String) async -> String? {
        if let token, let expiry, expiry > Date() { return token }

        var request = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        request.httpMethod = "POST"
        let basic = Data("\(clientID):".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = [
            .init(name: "grant_type", value: "https://oauth.reddit.com/grants/installed_client"),
            .init(name: "device_id", value: Self.deviceID()),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            Log.intelligence.notice("Reddit OAuth token request HTTP \(status, privacy: .public)")
            return nil
        }
        token = accessToken
        let lifetime = json["expires_in"] as? Double ?? 3600
        expiry = Date().addingTimeInterval(lifetime - 120)
        return accessToken
    }

    static let userAgent = "macOS:com.cjcarito.Lasso:0.1 (reverse-image identify)"

    /// Stable per-install device id (Reddit wants a unique 20–30 char id for installed_client).
    private static func deviceID() -> String {
        let key = "reddit.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(30))
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
