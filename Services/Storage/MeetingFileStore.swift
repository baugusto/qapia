import Foundation

public protocol MeetingFileStore: Sendable {
    func makeSegmentURL(meetingID: UUID, sequence: Int) throws -> URL
    func transcriptURL(meetingID: UUID) throws -> URL
    func summaryURL(meetingID: UUID) throws -> URL
    func writeTranscript(_ transcript: String, meetingID: UUID) throws
    func writeSummary(_ summary: String, meetingID: UUID) throws
    func deleteMeeting(meetingID: UUID) throws
}

public struct LocalMeetingFileStore: MeetingFileStore {
    private let rootURL: URL
    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Qapia/Meetings", isDirectory: true)
    }

    public func makeSegmentURL(meetingID: UUID, sequence: Int) throws -> URL {
        let audioDirectory = try meetingDirectory(meetingID)
            .appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )
        return audioDirectory.appendingPathComponent(
            String(format: "segment-%03d.m4a", sequence),
            isDirectory: false
        )
    }

    public func transcriptURL(meetingID: UUID) throws -> URL {
        try meetingDirectory(meetingID).appendingPathComponent("transcript.txt")
    }

    public func summaryURL(meetingID: UUID) throws -> URL {
        try meetingDirectory(meetingID).appendingPathComponent("summary.md")
    }

    public func writeTranscript(_ transcript: String, meetingID: UUID) throws {
        let url = try transcriptURL(meetingID: meetingID)
        try transcript.write(to: url, atomically: true, encoding: .utf8)
    }

    public func writeSummary(_ summary: String, meetingID: UUID) throws {
        let url = try summaryURL(meetingID: meetingID)
        try summary.write(to: url, atomically: true, encoding: .utf8)
    }

    public func deleteMeeting(meetingID: UUID) throws {
        let directory = rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func meetingDirectory(_ meetingID: UUID) throws -> URL {
        let directory = rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
