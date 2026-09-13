import Foundation
import XCTest
@testable import QapiaCore

final class OnDeviceSummaryIntegrationTests: XCTestCase {
    func testRealTranscriptProducesConciseExecutiveMinutesWhenRequested() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment[
            "QAPIA_ON_DEVICE_SUMMARY_FIXTURE"
        ] else {
            throw XCTSkip("Defina QAPIA_ON_DEVICE_SUMMARY_FIXTURE para validar a IA local.")
        }

        let transcript = try String(
            contentsOf: URL(fileURLWithPath: fixturePath),
            encoding: .utf8
        )
        let summary = try await OnDeviceSummaryProvider().generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        let headings = summary.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("## ") }
            .map { String($0.dropFirst(3)) }
        let summaryWordCount = summary.split(whereSeparator: \.isWhitespace).count
        let transcriptWordCount = transcript.split(whereSeparator: \.isWhitespace).count

        XCTAssertEqual(headings, SummaryTemplate.standardMeeting.sections)
        let conciseLimit = transcriptWordCount >= 1_200
            ? transcriptWordCount / 4
            : 350
        XCTAssertLessThan(summaryWordCount, min(1_200, conciseLimit))
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("Monjara"))
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("cão terranos"))
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("precisa de trocar aqui"))
        print("\n=== QAPIA ON-DEVICE EXECUTIVE MINUTES ===\n\(summary.prefix(4_000))\n=== END QAPIA ON-DEVICE EXECUTIVE MINUTES ===\n")
    }
}
