@preconcurrency import AVFoundation
import XCTest
@testable import QapiaCore

@MainActor
final class AudioSourceHealthTests: XCTestCase {
    func testFinalizedAudioValidationRejectsUnreadableOrTruncatedOutput() {
        XCTAssertNotNil(CoreAudioTapCaptureService.finalizedAudioValidationFailure(
            actualDuration: nil,
            expectedDuration: 6,
            isReadableToEnd: false
        ))
        XCTAssertNotNil(CoreAudioTapCaptureService.finalizedAudioValidationFailure(
            actualDuration: 1,
            expectedDuration: 6,
            isReadableToEnd: true
        ))
        XCTAssertNil(CoreAudioTapCaptureService.finalizedAudioValidationFailure(
            actualDuration: 5.9,
            expectedDuration: 6,
            isReadableToEnd: true
        ))
    }

    func testAtomicPromotionFailurePreservesPreviousOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("segment.m4a")
        let missingTemporaryURL = directory.appendingPathComponent("missing.m4a")
        let previousContents = Data("previous recording".utf8)
        try previousContents.write(to: outputURL)

        XCTAssertThrowsError(
            try CoreAudioTapCaptureService.atomicallyPromoteValidatedAudio(
                at: missingTemporaryURL,
                to: outputURL
            )
        )
        XCTAssertEqual(try Data(contentsOf: outputURL), previousContents)
    }

    func testCombinePromotesValidatedSiblingOverExistingOutput() async throws {
        let fixture = try makeAudioFixture(systemDuration: 1, microphoneDuration: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let previousContents = Data("previous recording".utf8)
        try previousContents.write(to: fixture.outputURL)

        let finalizedURL = try await CoreAudioTapCaptureService.combineAudioTracks(
            systemURL: fixture.systemURL,
            microphoneURL: fixture.microphoneURL,
            outputURL: fixture.outputURL
        )

        XCTAssertEqual(finalizedURL, fixture.outputURL)
        XCTAssertNotEqual(try Data(contentsOf: fixture.outputURL), previousContents)
        let outputDuration = try await duration(of: fixture.outputURL)
        XCTAssertGreaterThan(outputDuration, 0.9)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.microphoneURL.path))
        let leftoverExports = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("-qapia-") }
        XCTAssertTrue(leftoverExports.isEmpty)
    }

    func testDecodableSystemTrackWithWriterErrorIsIncludedAndWarned() async throws {
        let fixture = try makeAudioFixture(systemDuration: 1, microphoneDuration: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = try await CoreAudioTapCaptureService.finalizeAudioTracks(
            systemURL: fixture.systemURL,
            microphoneURL: fixture.microphoneURL,
            outputURL: fixture.outputURL,
            systemCaptureError: "Falha simulada no writer do sistema.",
            microphoneCaptureError: nil,
            systemStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            expectedTimelineDuration: 1
        )

        XCTAssertTrue(outcome.isDegraded)
        XCTAssertFalse(outcome.mayDeleteRawSources)
        XCTAssertTrue(outcome.includedSystemAudio)
        XCTAssertTrue(outcome.includedMicrophoneAudio)
        XCTAssertTrue(outcome.degradationReasons.contains { $0.contains("writer") })
        XCTAssertTrue(outcome.userWarning?.contains("writer") == true)
        XCTAssertGreaterThan(
            try toneMagnitude(
                frequency: 997,
                in: outcome.fileURL,
                analysisDuration: 0.20
            ),
            0.03,
            "Um CAF do sistema legível até o fim não pode ser descartado apenas por ter um erro de writer."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.microphoneURL.path))
    }

    func testTruncatedSystemTrackIsIncludedAndRawSourcesArePreserved() async throws {
        let fixture = try makeAudioFixture(systemDuration: 0.25, microphoneDuration: 6)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = try await CoreAudioTapCaptureService.finalizeAudioTracks(
            systemURL: fixture.systemURL,
            microphoneURL: fixture.microphoneURL,
            outputURL: fixture.outputURL,
            systemCaptureError: nil,
            microphoneCaptureError: nil,
            systemStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            expectedTimelineDuration: 6
        )

        XCTAssertTrue(outcome.isDegraded)
        XCTAssertFalse(outcome.mayDeleteRawSources)
        XCTAssertTrue(outcome.includedSystemAudio)
        XCTAssertTrue(outcome.includedMicrophoneAudio)
        XCTAssertTrue(outcome.degradationReasons.contains {
            $0.contains("Áudio do sistema") && $0.contains("truncada")
        })
        let outputDuration = try await duration(of: outcome.fileURL)
        XCTAssertGreaterThan(outputDuration, 5.5)
        let systemToneMagnitude = try toneMagnitude(
            frequency: 997,
            in: outcome.fileURL,
            analysisDuration: 0.20
        )
        XCTAssertGreaterThan(
            systemToneMagnitude,
            0.03,
            "O trecho remoto decodificável deve permanecer audível no M4A final."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.microphoneURL.path))
    }

    func testTruncatedMicrophoneTrackIsIncludedAndRawSourcesArePreserved() async throws {
        let fixture = try makeAudioFixture(systemDuration: 6, microphoneDuration: 0.25)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = try await CoreAudioTapCaptureService.finalizeAudioTracks(
            systemURL: fixture.systemURL,
            microphoneURL: fixture.microphoneURL,
            outputURL: fixture.outputURL,
            systemCaptureError: nil,
            microphoneCaptureError: nil,
            systemStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            expectedTimelineDuration: 6
        )

        XCTAssertTrue(outcome.isDegraded)
        XCTAssertFalse(outcome.mayDeleteRawSources)
        XCTAssertTrue(outcome.includedSystemAudio)
        XCTAssertTrue(outcome.includedMicrophoneAudio)
        XCTAssertTrue(outcome.degradationReasons.contains {
            $0.contains("Áudio do microfone") && $0.contains("truncada")
        })
        let outputDuration = try await duration(of: outcome.fileURL)
        XCTAssertGreaterThan(outputDuration, 5.5)
        let microphoneToneMagnitude = try toneMagnitude(
            frequency: 440,
            in: outcome.fileURL,
            analysisDuration: 0.20
        )
        XCTAssertGreaterThan(
            microphoneToneMagnitude,
            0.03,
            "O trecho decodificável do microfone deve permanecer audível no M4A final."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.microphoneURL.path))
    }

    func testLegitimateLateSystemStartUsesItsOwnExpectedDuration() async throws {
        let fixture = try makeAudioFixture(systemDuration: 5, microphoneDuration: 6)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = try await CoreAudioTapCaptureService.finalizeAudioTracks(
            systemURL: fixture.systemURL,
            microphoneURL: fixture.microphoneURL,
            outputURL: fixture.outputURL,
            systemCaptureError: nil,
            microphoneCaptureError: nil,
            systemStartedAtUptime: 101,
            microphoneStartedAtUptime: 100,
            expectedTimelineDuration: 6
        )

        XCTAssertFalse(outcome.isDegraded)
        XCTAssertTrue(outcome.includedSystemAudio)
        XCTAssertTrue(outcome.includedMicrophoneAudio)
        XCTAssertFalse(outcome.degradationReasons.contains { $0.contains("truncada") })
        let outputDuration = try await duration(of: outcome.fileURL)
        XCTAssertGreaterThan(outputDuration, 5.5)
    }

    private func makeAudioFixture(
        systemDuration: TimeInterval,
        microphoneDuration: TimeInterval
    ) throws -> AudioHealthFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let systemURL = directory.appendingPathComponent("segment-system.caf")
        let microphoneURL = directory.appendingPathComponent("segment-microphone.caf")
        let outputURL = directory.appendingPathComponent("segment.m4a")
        try writeHealthCAF(to: systemURL, duration: systemDuration, frequency: 997)
        try writeHealthCAF(to: microphoneURL, duration: microphoneDuration, frequency: 440)
        return AudioHealthFixture(
            directory: directory,
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL
        )
    }

    private func duration(of url: URL) async throws -> TimeInterval {
        let duration = try await AVURLAsset(url: url).load(.duration)
        return CMTimeGetSeconds(duration)
    }

    private func toneMagnitude(
        frequency: Double,
        in url: URL,
        analysisDuration: TimeInterval
    ) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let requestedFrameCount = AVAudioFrameCount(analysisDuration * format.sampleRate)
        guard requestedFrameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: requestedFrameCount
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer, frameCount: requestedFrameCount)
        guard buffer.frameLength > 0,
              let channels = buffer.floatChannelData else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var totalMagnitude = 0.0
        for channelIndex in 0..<channelCount {
            let samples = channels[channelIndex]
            var sineProjection = 0.0
            var cosineProjection = 0.0
            for frameIndex in 0..<frameCount {
                let phase = 2 * Double.pi * frequency * Double(frameIndex) / format.sampleRate
                let sample = Double(samples[frameIndex])
                sineProjection += sample * sin(phase)
                cosineProjection += sample * cos(phase)
            }
            totalMagnitude += 2 * hypot(sineProjection, cosineProjection) / Double(frameCount)
        }
        return totalMagnitude / Double(channelCount)
    }
}

private struct AudioHealthFixture {
    let directory: URL
    let systemURL: URL
    let microphoneURL: URL
    let outputURL: URL
}

private func writeHealthCAF(
    to url: URL,
    duration: TimeInterval,
    frequency: Double
) throws {
    let sampleRate = 48_000.0
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ),
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(duration * sampleRate)
    ),
    let samples = buffer.floatChannelData?[0] else {
        throw CocoaError(.fileWriteUnknown)
    }
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
        samples[frame] = 0.16 * Float(
            sin(2 * Double.pi * frequency * Double(frame) / sampleRate)
        )
    }
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try file.write(from: buffer)
}
