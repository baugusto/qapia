import Foundation
import XCTest
@testable import QapiaCore

final class TranscriptionPerformanceTests: XCTestCase {
    func testThreadCountPrefersPerformanceCoresAndRemainsBounded() {
        XCTAssertEqual(
            WhisperPerformanceConfiguration.recommendedThreadCount(
                performanceCoreCount: 6,
                physicalCoreCount: 10,
                activeProcessorCount: 10
            ),
            6
        )
        XCTAssertEqual(
            WhisperPerformanceConfiguration.recommendedThreadCount(
                performanceCoreCount: 12,
                physicalCoreCount: 12,
                activeProcessorCount: 12
            ),
            8
        )
        XCTAssertEqual(
            WhisperPerformanceConfiguration.recommendedThreadCount(
                performanceCoreCount: nil,
                physicalCoreCount: nil,
                activeProcessorCount: 2
            ),
            2
        )
    }

    func testWhisperParametersUseConfiguredThreadsWithoutChangingAccuracyKnobs() {
        let profile = WhisperDecodingProfile.highFidelityPortuguese
        let parameters = WhisperEngine.parameters(for: profile)

        XCTAssertEqual(parameters.n_threads, WhisperPerformanceConfiguration.inferenceThreadCount)
        XCTAssertEqual(parameters.greedy.best_of, 5)
        XCTAssertFalse(parameters.no_timestamps)
        XCTAssertTrue(parameters.no_context)
        XCTAssertFalse(parameters.single_segment)
    }

    func testSilenceGateMatchesP99BoundaryWithoutSorting() {
        let quietWindow = Array(repeating: Float(0.0001), count: 320)
        let activeWindow = (0..<320).map { index in
            Float(0.003 * sin(2 * Double.pi * 220 * Double(index) / 16_000))
        }

        XCTAssertTrue(
            WhisperAudioContentAnalyzer.isEffectivelySilent(
                Array(repeating: quietWindow, count: 99).flatMap { $0 } + activeWindow
            )
        )
        XCTAssertFalse(
            WhisperAudioContentAnalyzer.isEffectivelySilent(
                Array(repeating: quietWindow, count: 98).flatMap { $0 }
                    + activeWindow + activeWindow
            )
        )
    }

    func testTranscriptionBatchResourcesAreReleasedAfterSuccess() async throws {
        let lifecycle = BatchLifecycleWhisperService(result: .success("Conteúdo útil."))
        let service = TranscriptionService(whisperService: lifecycle)

        _ = try await service.generateTranscript(segments: [makeSegment()])

        XCTAssertEqual(lifecycle.finishCount, 1)
    }

    func testTranscriptionBatchResourcesAreReleasedAfterFailure() async {
        let lifecycle = BatchLifecycleWhisperService(
            result: .failure(WhisperError.transcriptionFailed("falha de teste"))
        )
        let service = TranscriptionService(whisperService: lifecycle)

        do {
            _ = try await service.generateTranscript(segments: [makeSegment()])
            XCTFail("A transcrição deveria falhar.")
        } catch {
            XCTAssertEqual(lifecycle.finishCount, 1)
        }
    }

    private func makeSegment() -> RecordingSegment {
        RecordingSegment(
            meetingID: UUID(),
            sequence: 1,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("segment.m4a"),
            recordedDuration: 3_600
        )
    }
}

private final class BatchLifecycleWhisperService: WhisperService, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<String, Error>
    private var storedFinishCount = 0

    init(result: Result<String, Error>) {
        self.result = result
    }

    var finishCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFinishCount
    }

    func transcribe(segment: RecordingSegment) async throws -> String {
        try result.get()
    }

    func finishTranscriptionBatch() {
        lock.lock()
        storedFinishCount += 1
        lock.unlock()
    }
}
