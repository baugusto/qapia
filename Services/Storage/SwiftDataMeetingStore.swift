import Foundation
import SwiftData

@Model
final class StoredRecordingSegment {
    @Attribute(.unique) var id: UUID
    var meetingID: UUID
    var sequence: Int
    var filePath: String
    var recordedDuration: TimeInterval
    var createdAt: Date
    var captureWarning: String?

    init(segment: RecordingSegment) {
        id = segment.id
        meetingID = segment.meetingID
        sequence = segment.sequence
        filePath = segment.fileURL.path
        recordedDuration = segment.recordedDuration
        createdAt = segment.createdAt
        captureWarning = segment.captureWarning
    }

    var value: RecordingSegment {
        RecordingSegment(
            id: id,
            meetingID: meetingID,
            sequence: sequence,
            fileURL: URL(fileURLWithPath: filePath),
            recordedDuration: recordedDuration,
            createdAt: createdAt,
            captureWarning: captureWarning
        )
    }
}

@Model
final class StoredMeeting {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var finishedAt: Date?
    var recordedDuration: TimeInterval
    var title: String
    var stateRawValue: String
    var templateId: String
    var customTemplateStructure: String
    var transcript: String
    var summary: String
    var participantsJSON: String = "[]"
    var calendarEventID: String?
    var scheduledStart: Date?
    var scheduledEnd: Date?
    @Relationship(deleteRule: .cascade) var recordingSegments: [StoredRecordingSegment]

    init(meeting: Meeting) {
        id = meeting.id
        createdAt = meeting.createdAt
        finishedAt = meeting.finishedAt
        recordedDuration = meeting.recordedDuration
        title = meeting.title
        stateRawValue = meeting.state.rawValue
        templateId = meeting.templateId
        customTemplateStructure = meeting.customTemplateStructure
        transcript = meeting.transcript
        summary = meeting.summary
        participantsJSON = Self.encodeParticipants(meeting.participants)
        calendarEventID = meeting.calendarEventID
        scheduledStart = meeting.scheduledStart
        scheduledEnd = meeting.scheduledEnd
        recordingSegments = meeting.recordingSegments.map(StoredRecordingSegment.init)
    }

    func update(from meeting: Meeting, context: ModelContext) {
        createdAt = meeting.createdAt
        finishedAt = meeting.finishedAt
        recordedDuration = meeting.recordedDuration
        title = meeting.title
        stateRawValue = meeting.state.rawValue
        templateId = meeting.templateId
        customTemplateStructure = meeting.customTemplateStructure
        transcript = meeting.transcript
        summary = meeting.summary
        participantsJSON = Self.encodeParticipants(meeting.participants)
        calendarEventID = meeting.calendarEventID
        scheduledStart = meeting.scheduledStart
        scheduledEnd = meeting.scheduledEnd

        recordingSegments.forEach(context.delete)
        recordingSegments = meeting.recordingSegments.map { segment in
            let stored = StoredRecordingSegment(segment: segment)
            context.insert(stored)
            return stored
        }
    }

    var value: Meeting {
        Meeting(
            id: id,
            createdAt: createdAt,
            finishedAt: finishedAt,
            recordedDuration: recordedDuration,
            title: title,
            state: MeetingState(rawValue: stateRawValue) ?? .failed,
            templateId: templateId,
            customTemplateStructure: customTemplateStructure,
            transcript: transcript,
            summary: summary,
            participants: Self.decodeParticipants(participantsJSON),
            calendarEventID: calendarEventID,
            scheduledStart: scheduledStart,
            scheduledEnd: scheduledEnd,
            recordingSegments: recordingSegments
                .map(\.value)
                .sorted { $0.sequence < $1.sequence }
        )
    }

    private static func encodeParticipants(_ participants: [String]) -> String {
        guard let data = try? JSONEncoder().encode(participants),
              let value = String(data: data, encoding: .utf8) else { return "[]" }
        return value
    }

    private static func decodeParticipants(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let participants = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return participants
    }
}

@MainActor
public final class SwiftDataMeetingStore: MeetingStore {
    private let container: ModelContainer
    private let context: ModelContext

    public init(storeURL: URL? = nil, inMemory: Bool = false) throws {
        let schema = Schema([
            StoredMeeting.self,
            StoredRecordingSegment.self
        ])

        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(
                "QAPia",
                schema: schema,
                isStoredInMemoryOnly: true
            )
        } else {
            let resolvedURL = storeURL ?? Self.defaultStoreURL
            try FileManager.default.createDirectory(
                at: resolvedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(
                "QAPia",
                schema: schema,
                url: resolvedURL
            )
        }

        container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public func loadMeetings() throws -> [Meeting] {
        let storedMeetings = try context.fetch(FetchDescriptor<StoredMeeting>())
        return storedMeetings
            .map(\.value)
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ meeting: Meeting) throws {
        try upsert(meeting)
        try context.save()
    }

    public func delete(id: UUID) throws {
        let storedMeetings = try context.fetch(FetchDescriptor<StoredMeeting>())
        guard let stored = storedMeetings.first(where: { $0.id == id }) else { return }
        context.delete(stored)
        try context.save()
    }

    private func upsert(_ meeting: Meeting) throws {
        let storedMeetings = try context.fetch(FetchDescriptor<StoredMeeting>())
        if let stored = storedMeetings.first(where: { $0.id == meeting.id }) {
            stored.update(from: meeting, context: context)
        } else {
            context.insert(StoredMeeting(meeting: meeting))
        }
    }

    private static var defaultStoreURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Qapia/Persistence", isDirectory: true)
        .appendingPathComponent("QAPia.store", isDirectory: false)
    }
}
