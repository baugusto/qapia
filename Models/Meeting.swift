import Foundation

public struct Meeting: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var finishedAt: Date?
    public var recordedDuration: TimeInterval
    public var title: String
    public var state: MeetingState
    public var templateId: String
    public var customTemplateStructure: String
    public var transcript: String
    public var summary: String
    public var participants: [String]
    public var calendarEventID: String?
    public var scheduledStart: Date?
    public var scheduledEnd: Date?
    public var recordingSegments: [RecordingSegment]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        recordedDuration: TimeInterval = 0,
        title: String,
        state: MeetingState = .idle,
        templateId: String = SummaryTemplate.general.id,
        customTemplateStructure: String = "",
        transcript: String = "",
        summary: String = "",
        participants: [String] = [],
        calendarEventID: String? = nil,
        scheduledStart: Date? = nil,
        scheduledEnd: Date? = nil,
        recordingSegments: [RecordingSegment] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.recordedDuration = recordedDuration
        self.title = title
        self.state = state
        self.templateId = templateId
        self.customTemplateStructure = customTemplateStructure
        self.transcript = transcript
        self.summary = summary
        self.participants = participants
        self.calendarEventID = calendarEventID
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.recordingSegments = recordingSegments
    }

    public var durationText: String {
        let totalSeconds = max(0, Int(recordedDuration))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d h %02d min %02d s", hours, minutes, seconds)
        }
        return String(format: "%d min %02d s", minutes, seconds)
    }

    public var recordingDateText: String {
        createdAt.formatted(.dateTime.day().month(.abbreviated).year())
    }

    public var recordingTimeText: String {
        createdAt.formatted(date: .omitted, time: .shortened)
    }

    public var recordingMetadataText: String {
        "\(recordingDateText) · \(recordingTimeText) · \(durationText)"
    }

    public var sidebarMetadata: String {
        switch state {
        case .preparingAudio, .transcribing, .transcribed, .summarizing:
            return "Processando em segundo plano"
        default:
            break
        }
        return "\(dateLabel) · \(durationText)"
    }

    public var dateLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(createdAt) { return "Hoje" }
        if calendar.isDateInYesterday(createdAt) { return "Ontem" }
        return createdAt.formatted(.dateTime.day().month(.abbreviated))
    }

    public var participantsText: String {
        participants.joined(separator: ", ")
    }

    public func participantPreview(limit: Int = 4) -> String {
        guard limit > 0 else { return "" }
        let visible = participants.prefix(limit).joined(separator: ", ")
        let remaining = participants.count - min(limit, participants.count)
        return remaining > 0 ? "\(visible)  +\(remaining)" : visible
    }

    public var searchableText: String {
        [
            title,
            participants.joined(separator: " "),
            createdAt.formatted(date: .long, time: .shortened),
            createdAt.formatted(date: .numeric, time: .shortened),
            createdAt.ISO8601Format(),
            scheduledStart?.formatted(date: .long, time: .shortened) ?? "",
            scheduledStart?.formatted(date: .numeric, time: .shortened) ?? "",
            transcript,
            summary
        ].joined(separator: "\n")
    }

    public var missingRecordingSegmentCount: Int {
        recordingSegments.reduce(into: 0) { count, segment in
            if !FileManager.default.fileExists(atPath: segment.fileURL.path) {
                count += 1
            }
        }
    }

    public var hasUnavailableAudio: Bool {
        missingRecordingSegmentCount > 0
    }

    public var captureWarnings: [String] {
        recordingSegments.compactMap(\.captureWarning)
    }

    public static let mockHistory: [Meeting] = [
        Meeting(
            id: UUID(uuidString: "A0A00000-0000-4000-8000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1_756_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_756_001_920),
            recordedDuration: 1_920,
            title: "Reunião com Ana",
            state: .completed,
            transcript: "Ana: Vamos revisar os próximos passos.\nVocê: Eu fico com a documentação e o acompanhamento.\nAna: Perfeito. Marcamos o próximo check-in para sexta.",
            summary: "Resumo executivo\n\nRevisamos os próximos passos do lançamento e alinhamos responsáveis para esta semana."
        ),
        Meeting(
            id: UUID(uuidString: "A0A00000-0000-4000-8000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 1_755_900_000),
            finishedAt: Date(timeIntervalSince1970: 1_755_901_080),
            recordedDuration: 1_080,
            title: "Planejamento de produto",
            state: .completed,
            transcript: "Definimos o escopo da próxima entrega e os riscos que precisam de acompanhamento.",
            summary: "Resumo executivo\n\nEscopo e riscos foram definidos para a próxima entrega."
        ),
        Meeting(
            id: UUID(uuidString: "A0A00000-0000-4000-8000-000000000003")!,
            createdAt: Date(timeIntervalSince1970: 1_755_800_000),
            finishedAt: Date(timeIntervalSince1970: 1_755_800_720),
            recordedDuration: 720,
            title: "Alinhamento comercial",
            state: .completed,
            transcript: "Alinhamos as prioridades comerciais da semana.",
            summary: "Resumo executivo\n\nAs prioridades comerciais da semana foram alinhadas."
        )
    ]
}
