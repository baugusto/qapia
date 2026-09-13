import Foundation

public struct RecordingSegment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let sequence: Int
    public let fileURL: URL
    public let recordedDuration: TimeInterval
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        sequence: Int,
        fileURL: URL,
        recordedDuration: TimeInterval,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sequence = sequence
        self.fileURL = fileURL
        self.recordedDuration = recordedDuration
        self.createdAt = createdAt
    }
}
