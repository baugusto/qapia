import Foundation

public struct CalendarParticipant: Codable, Hashable, Identifiable, Sendable {
    public let email: String
    public let displayName: String?
    public let isOrganizer: Bool
    public let isCurrentUser: Bool

    public init(
        email: String,
        displayName: String? = nil,
        isOrganizer: Bool = false,
        isCurrentUser: Bool = false
    ) {
        self.email = email
        self.displayName = displayName
        self.isOrganizer = isOrganizer
        self.isCurrentUser = isCurrentUser
    }

    public var id: String { email.lowercased() }
    public var preferredName: String {
        let cleanName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleanName.isEmpty ? email : cleanName
    }
}

public struct CalendarEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let participants: [CalendarParticipant]
    public let location: String?
    public let meetingURL: URL?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        participants: [CalendarParticipant] = [],
        location: String? = nil,
        meetingURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.participants = participants
        self.location = location
        self.meetingURL = meetingURL
    }

    public var participantNames: [String] {
        participants
            .filter { !$0.isCurrentUser }
            .map(\.preferredName)
    }

    public func isRecordingSuggestion(at date: Date = Date()) -> Bool {
        date >= start.addingTimeInterval(-10 * 60) && date < end
    }
}

public struct GoogleCalendarAccount: Codable, Hashable, Sendable {
    public let email: String

    public init(email: String) {
        self.email = email
    }
}

public enum CalendarAgenda {
    public static func events(
        from events: [CalendarEvent],
        on day: Date,
        relativeTo now: Date = Date(),
        limit: Int = 5,
        calendar: Calendar = .current
    ) -> [CalendarEvent] {
        guard limit > 0 else { return [] }
        let isToday = calendar.isDate(day, inSameDayAs: now)
        return Array(
            events
                .filter { event in
                    calendar.isDate(event.start, inSameDayAs: day)
                        && (!isToday || event.end > now)
                }
                .sorted { lhs, rhs in
                    if lhs.start == rhs.start { return lhs.title < rhs.title }
                    return lhs.start < rhs.start
                }
                .prefix(limit)
        )
    }
}
