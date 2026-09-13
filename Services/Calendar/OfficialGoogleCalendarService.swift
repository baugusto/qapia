import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

enum NativeGoogleAuthenticationCallbackDispatcher {
    nonisolated static func make(
        handler: @escaping @MainActor @Sendable (URL?, (any Error)?) -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { callbackURL, error in
            Task { @MainActor in
                handler(callbackURL, error)
            }
        }
    }
}

@MainActor
public final class GoogleCalendarService: GoogleCalendarServing {
    private static let calendarScope = "https://www.googleapis.com/auth/calendar.events.readonly"

    private let configuration: GoogleOAuthConfiguration?
    private let session: URLSession
    private let tokenStore: NativeGoogleTokenStore
    private var token: NativeGoogleOAuthToken?
    private var authenticationSession: ASWebAuthenticationSession?
    private var presentationContext: NativeGooglePresentationContext?

    public init(
        configuration: GoogleOAuthConfiguration? = .bundled(),
        session: URLSession = .shared,
        tokenStore: NativeGoogleTokenStore = NativeGoogleTokenStore()
    ) {
        self.configuration = configuration
        self.session = session
        self.tokenStore = tokenStore
        let restoredToken = tokenStore.load()
        self.token = restoredToken?.clientID == configuration?.clientID ? restoredToken : nil
    }

    public var isConfigured: Bool { configuration != nil }

    public func restoreAccount() async -> GoogleCalendarAccount? {
        guard let email = token?.email, !email.isEmpty else { return nil }
        return GoogleCalendarAccount(email: email)
    }

    public func connect() async throws -> GoogleCalendarAccount {
        guard let configuration,
              let callbackScheme = configuration.callbackScheme else {
            throw GoogleCalendarError.missingConfiguration
        }

        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(byteCount: 24)
        let redirectURI = "\(callbackScheme):/oauthredirect"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email \(Self.calendarScope)"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authorizationURL = components.url else { throw GoogleCalendarError.invalidResponse }

        let parameters = try await authenticate(at: authorizationURL, callbackScheme: callbackScheme)
        if let error = parameters["error"] {
            if error == "access_denied" { throw GoogleCalendarError.authorizationCancelled }
            throw GoogleCalendarError.authorizationFailed(error)
        }
        guard parameters["state"] == state, let code = parameters["code"] else {
            throw GoogleCalendarError.invalidResponse
        }

        var connectedToken = try await exchangeToken([
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ])
        connectedToken.clientID = configuration.clientID
        connectedToken.email = try await fetchEmail(accessToken: connectedToken.accessToken)
        try tokenStore.save(connectedToken)
        token = connectedToken
        return GoogleCalendarAccount(email: connectedToken.email ?? "Conta Google")
    }

    public func disconnect() async {
        if let value = token?.refreshToken ?? token?.accessToken,
           let url = URL(string: "https://oauth2.googleapis.com/revoke?token=\(value.nativeURLQueryEncoded)") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            _ = try? await session.data(for: request)
        }
        tokenStore.delete()
        token = nil
    }

    public func upcomingEvents(from: Date, through: Date) async throws -> [CalendarEvent] {
        let accessToken = try await validAccessToken()
        var components = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/primary/events"
        )!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: Self.rfc3339.string(from: from)),
            URLQueryItem(name: "timeMax", value: Self.rfc3339.string(from: through)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "100")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(OfficialGoogleAPIErrorEnvelope.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw GoogleCalendarError.apiFailed(message)
        }
        let payload = try JSONDecoder().decode(OfficialGoogleEventsResponse.self, from: data)
        return payload.items.compactMap(\.calendarEvent)
    }

    private func validAccessToken() async throws -> String {
        guard var current = token else { throw GoogleCalendarError.sessionExpired }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        guard let refreshToken = current.refreshToken, let configuration else {
            throw GoogleCalendarError.sessionExpired
        }
        let refreshed = try await exchangeToken([
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
        current.accessToken = refreshed.accessToken
        current.expiresAt = refreshed.expiresAt
        if let replacement = refreshed.refreshToken { current.refreshToken = replacement }
        try tokenStore.save(current)
        token = current
        return current.accessToken
    }

    private func authenticate(at url: URL, callbackScheme: String) async throws -> [String: String] {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            throw GoogleCalendarError.authorizationFailed("a janela do aplicativo não está disponível")
        }
        let context = NativeGooglePresentationContext(window: window)
        presentationContext = context

        return try await withCheckedThrowingContinuation { continuation in
            let callback = NativeGoogleAuthenticationCallbackDispatcher.make { [weak self] callbackURL, error in
                guard let self else {
                    continuation.resume(
                        throwing: GoogleCalendarError.authorizationFailed("a sessão de autenticação foi encerrada")
                    )
                    return
                }
                self.authenticationSession = nil
                self.presentationContext = nil
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                       nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                        continuation.resume(throwing: GoogleCalendarError.authorizationCancelled)
                    } else {
                        continuation.resume(
                            throwing: GoogleCalendarError.authorizationFailed(error.localizedDescription)
                        )
                    }
                    return
                }
                guard let callbackURL,
                      let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
                    continuation.resume(throwing: GoogleCalendarError.invalidResponse)
                    return
                }
                continuation.resume(returning: Dictionary(uniqueKeysWithValues: callback.queryItems?.map {
                    ($0.name, $0.value ?? "")
                } ?? []))
            }
            let webSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme,
                completionHandler: callback
            )
            webSession.presentationContextProvider = context
            webSession.prefersEphemeralWebBrowserSession = false
            authenticationSession = webSession
            guard webSession.start() else {
                authenticationSession = nil
                presentationContext = nil
                continuation.resume(
                    throwing: GoogleCalendarError.authorizationFailed("não foi possível abrir o navegador")
                )
                return
            }
        }
    }

    private func exchangeToken(_ body: [String: String]) async throws -> NativeGoogleOAuthToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .sorted { $0.key < $1.key }
            .map { "\($0.key.nativeURLQueryEncoded)=\($0.value.nativeURLQueryEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let oauthError = try? JSONDecoder().decode(NativeGoogleOAuthError.self, from: data)
            let details = oauthError?.errorDescription ?? oauthError?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw GoogleCalendarError.authorizationFailed(details)
        }
        let result = try JSONDecoder().decode(NativeGoogleTokenResponse.self, from: data)
        return NativeGoogleOAuthToken(
            accessToken: result.accessToken,
            refreshToken: result.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(result.expiresIn)),
            email: nil,
            clientID: nil
        )
    }

    private func fetchEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let email = try? JSONDecoder().decode(NativeGoogleUserInfo.self, from: data).email else {
            throw GoogleCalendarError.invalidResponse
        }
        return email
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct OfficialGoogleAPIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError
}

private struct OfficialGoogleEventsResponse: Decodable {
    let items: [OfficialGoogleEvent]
}

private struct OfficialGoogleEvent: Decodable {
    struct EventDate: Decodable { let dateTime: String?; let date: String? }
    struct Attendee: Decodable {
        let email: String?
        let displayName: String?
        let organizer: Bool?
        let `self`: Bool?
    }
    struct ConferenceData: Decodable {
        struct EntryPoint: Decodable { let entryPointType: String?; let uri: String? }
        let entryPoints: [EntryPoint]?
    }

    let id: String
    let summary: String?
    let status: String?
    let start: EventDate
    let end: EventDate
    let attendees: [Attendee]?
    let location: String?
    let hangoutLink: String?
    let conferenceData: ConferenceData?

    var calendarEvent: CalendarEvent? {
        guard status != "cancelled",
              let startValue = start.dateTime,
              let endValue = end.dateTime,
              let startDate = Self.parseDate(startValue),
              let endDate = Self.parseDate(endValue) else { return nil }
        let videoURL = hangoutLink.flatMap(URL.init(string:))
            ?? conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri.flatMap(URL.init(string:))
        return CalendarEvent(
            id: id,
            title: summary?.trimmingCharacters(in: .whitespacesAndNewlines).officialNilIfEmpty
                ?? "Reunião sem título",
            start: startDate,
            end: endDate,
            participants: (attendees ?? []).compactMap { attendee in
                guard let email = attendee.email else { return nil }
                return CalendarParticipant(
                    email: email,
                    displayName: attendee.displayName,
                    isOrganizer: attendee.organizer ?? false,
                    isCurrentUser: attendee.`self` ?? false
                )
            },
            location: location,
            meetingURL: videoURL
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

private extension String {
    var officialNilIfEmpty: String? { isEmpty ? nil : self }

    var nativeURLQueryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .nativeGoogleQueryValueAllowed) ?? self
    }
}

private extension CharacterSet {
    static let nativeGoogleQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

private final class NativeGooglePresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? NSApp.windows.first ?? NSWindow()
    }
}

private struct NativeGoogleTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct NativeGoogleOAuthError: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct NativeGoogleUserInfo: Decodable {
    let email: String
}

private struct NativeGoogleOAuthToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var email: String?
    var clientID: String?
}

public final class NativeGoogleTokenStore: @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "br.com.qapia.app.google-calendar", account: String = "oauth-native") {
        self.service = service
        self.account = account
    }

    fileprivate func load() -> NativeGoogleOAuthToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(NativeGoogleOAuthToken.self, from: data)
    }

    fileprivate func save(_ token: NativeGoogleOAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw GoogleCalendarError.authorizationFailed("não foi possível proteger a sessão no Chaveiro")
            }
        } else if status != errSecSuccess {
            throw GoogleCalendarError.authorizationFailed("não foi possível atualizar a sessão no Chaveiro")
        }
    }

    fileprivate func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
