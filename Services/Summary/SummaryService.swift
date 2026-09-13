import Foundation

public struct SummaryService: Sendable {
    private let provider: any SummaryProvider
    private let fileStore: any MeetingFileStore

    public init(
        provider: any SummaryProvider,
        fileStore: any MeetingFileStore = LocalMeetingFileStore()
    ) {
        self.provider = provider
        self.fileStore = fileStore
    }

    public func generateSummary(
        meetingID: UUID,
        transcript: String,
        template: SummaryTemplate
    ) async throws -> String {
        let summary = try await generateSummaryText(
            transcript: transcript,
            template: template
        )
        try Task.checkCancellation()
        try fileStore.writeSummary(summary, meetingID: meetingID)
        return summary
    }

    public func generateSummaryText(
        transcript: String,
        template: SummaryTemplate
    ) async throws -> String {
        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: template
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !summary.isEmpty else { throw SummaryProviderError.emptySummary }
        return summary
    }
}
