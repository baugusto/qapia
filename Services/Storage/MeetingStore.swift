import Foundation

@MainActor
public protocol MeetingStore: AnyObject {
    func loadMeetings() throws -> [Meeting]
    func save(_ meeting: Meeting) throws
    func delete(id: UUID) throws
}

@MainActor
public final class MockMeetingStore: MeetingStore {
    private var meetings: [Meeting]

    public init(meetings: [Meeting] = Meeting.mockHistory) {
        self.meetings = meetings
    }

    public func loadMeetings() throws -> [Meeting] {
        meetings
    }

    public func save(_ meeting: Meeting) throws {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
    }

    public func delete(id: UUID) throws {
        meetings.removeAll { $0.id == id }
    }
}

@MainActor
public final class UnavailableMeetingStore: MeetingStore {
    private let underlyingError: Error

    public init(error: Error) {
        self.underlyingError = error
    }

    public func loadMeetings() throws -> [Meeting] {
        throw underlyingError
    }

    public func save(_ meeting: Meeting) throws {
        throw underlyingError
    }

    public func delete(id: UUID) throws {
        throw underlyingError
    }
}

public enum MeetingStoreError: LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return "Não foi possível acessar o histórico local: \(message)"
        }
    }
}

@MainActor
public enum MeetingStoreFactory {
    public static func makePersistentStore() -> any MeetingStore {
        do {
            return try SwiftDataMeetingStore()
        } catch {
            return UnavailableMeetingStore(
                error: MeetingStoreError.unavailable(error.localizedDescription)
            )
        }
    }
}

@MainActor
public final class EmptyMeetingStore: MeetingStore {
    public init() {}

    public func loadMeetings() throws -> [Meeting] {
        []
    }

    public func save(_ meeting: Meeting) throws {
    }

    public func delete(id: UUID) throws {
    }
}
