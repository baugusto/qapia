import Foundation

@MainActor
public protocol GoogleCalendarServing: AnyObject {
    var isConfigured: Bool { get }
    func restoreAccount() async -> GoogleCalendarAccount?
    func connect() async throws -> GoogleCalendarAccount
    func disconnect() async
    func upcomingEvents(from: Date, through: Date) async throws -> [CalendarEvent]
}

public enum GoogleCalendarError: LocalizedError, Equatable {
    case missingConfiguration
    case authorizationCancelled
    case authorizationFailed(String)
    case invalidResponse
    case sessionExpired
    case apiFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "A integração ainda precisa de um Client ID do Google do tipo iOS, vinculado ao QAP.ia."
        case .authorizationCancelled:
            return "A conexão com o Google foi cancelada."
        case let .authorizationFailed(message):
            return "Não foi possível conectar ao Google: \(message)"
        case .invalidResponse:
            return "O Google retornou uma resposta que não pôde ser lida."
        case .sessionExpired:
            return "A sessão do Google expirou. Conecte a conta novamente."
        case let .apiFailed(message):
            return "Não foi possível consultar o Google Calendar: \(message)"
        }
    }
}

public struct GoogleOAuthConfiguration: Sendable {
    public let clientID: String

    public init(clientID: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func bundled(bundle: Bundle = .main) -> GoogleOAuthConfiguration? {
        let clientID = (bundle.object(forInfoDictionaryKey: "QAPiaGoogleClientID") as? String) ?? ""
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return GoogleOAuthConfiguration(clientID: clientID)
    }
}
