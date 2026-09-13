@preconcurrency import AVFoundation
import AudioToolbox
import XCTest
@testable import QapiaCore

@MainActor
final class WhisperAudioDecoderTests: XCTestCase {
    func testDecodesGeneratedStereoCAFToWhisperFormat() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cafURL = rootURL.appendingPathComponent("stereo.caf")
        try writeCAF(
            to: cafURL,
            duration: 0.5,
            frequencies: [440, 880]
        )

        let result = try await WhisperAudioDecoder.decode(from: cafURL)
        let samples = result.samples

        XCTAssertEqual(samples.count, 8_000, accuracy: 64)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(rootMeanSquare(samples), 0.05)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testDecodesGeneratedTwoTrackPCMContainer() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let systemURL = rootURL.appendingPathComponent("system.caf")
        let microphoneURL = rootURL.appendingPathComponent("microphone.caf")
        let multitrackURL = rootURL.appendingPathComponent("multitrack.mov")
        try writeCAF(to: systemURL, duration: 0.5, frequencies: [330])
        try writeCAF(to: microphoneURL, duration: 0.5, frequencies: [660])
        try await exportPassthrough(
            sources: [systemURL, microphoneURL],
            destination: multitrackURL,
            fileType: .mov
        )

        let asset = AVURLAsset(url: multitrackURL)
        let exportedTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(exportedTracks.count, 2)

        let samples = try await WhisperAudioDecoder.decodeMonoSamples(from: multitrackURL)

        XCTAssertEqual(samples.count, 8_000, accuracy: 64)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(rootMeanSquare(samples), 0.05)
    }

    func testDecodesGeneratedAppleM4AWithoutChannelLayoutMetadata() async throws {
        guard systemHasAACDecoder else {
            throw XCTSkip(
                "O sandbox de testes não expõe o codec AAC do macOS; este teste é obrigatório no job sem sandbox."
            )
        }

        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let systemURL = rootURL.appendingPathComponent("system.caf")
        let microphoneURL = rootURL.appendingPathComponent("microphone.caf")
        let m4aURL = rootURL.appendingPathComponent("meeting.m4a")
        try writeCAF(to: systemURL, duration: 0.5, frequencies: [300, 600])
        try writeCAF(to: microphoneURL, duration: 0.5, frequencies: [900])
        try await exportAppleM4A(
            sources: [systemURL, microphoneURL],
            destination: m4aURL
        )

        let samples = try await WhisperAudioDecoder.decodeMonoSamples(from: m4aURL)

        XCTAssertEqual(samples.count, 8_000, accuracy: 128)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(rootMeanSquare(samples), 0.03)
    }

    func testPreservesUsefulPrefixAndWarnsWhenCAFEndsAbruptly() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cafURL = rootURL.appendingPathComponent("interrupted.caf")
        try writeCAF(to: cafURL, duration: 2, frequencies: [440])

        let completeData = try Data(contentsOf: cafURL)
        let truncatedByteCount = Int(Double(completeData.count) * 0.72)
        try Data(completeData.prefix(truncatedByteCount)).write(to: cafURL, options: .atomic)

        let result = try await WhisperAudioDecoder.decode(from: cafURL)

        XCTAssertGreaterThanOrEqual(result.samples.count, 8_000)
        XCTAssertLessThan(result.samples.count, 32_000)
        XCTAssertTrue(result.samples.allSatisfy(\.isFinite))
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.warnings.joined().contains("preservou"))
    }

    func testRejectsAbruptCAFWithoutMinimumUsefulAudio() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let cafURL = rootURL.appendingPathComponent("too-short.caf")
        try writeCAF(to: cafURL, duration: 2, frequencies: [440])

        let completeData = try Data(contentsOf: cafURL)
        let truncatedByteCount = Int(Double(completeData.count) * 0.10)
        try Data(completeData.prefix(truncatedByteCount)).write(to: cafURL, options: .atomic)

        do {
            _ = try await WhisperAudioDecoder.decode(from: cafURL)
            XCTFail("Um fragmento inferior a 0,5 s não deve ser enviado ao Whisper.")
        } catch is WhisperModelError {
            // Expected: a tiny corrupt fragment is not a trustworthy recording.
        }
    }

    func testCancellationTokenBridgesSwiftCancellationToWhisperCallback() {
        let token = WhisperCancellationToken()
        let userData = Unmanaged.passUnretained(token).toOpaque()

        XCTAssertFalse(WhisperCancellationToken.isCancellationRequested(userData))
        token.cancel()
        XCTAssertTrue(WhisperCancellationToken.isCancellationRequested(userData))
    }

    func testDecoderHonorsCancellationBeforeOpeningAudio() async throws {
        let task = Task {
            try await WhisperAudioDecoder.decodeMonoSamples(
                from: URL(fileURLWithPath: "/arquivo-que-nao-deve-ser-aberto.caf")
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A decodificação cancelada deveria terminar com CancellationError.")
        } catch is CancellationError {
            // Expected.
        }
    }

    private var systemHasAACDecoder: Bool {
        var formatID = kAudioFormatMPEG4AAC
        var propertySize: UInt32 = 0
        let status = AudioFormatGetPropertyInfo(
            kAudioFormatProperty_Decoders,
            UInt32(MemoryLayout.size(ofValue: formatID)),
            &formatID,
            &propertySize
        )
        return status == noErr && propertySize > 0
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCAF(
        to url: URL,
        duration: TimeInterval,
        frequencies: [Double]
    ) throws {
        let sampleRate = 48_000.0
        try autoreleasepool {
            let format = try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: AVAudioChannelCount(frequencies.count),
                    interleaved: true
                )
            )
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
            let frameCount = AVAudioFrameCount(sampleRate * duration)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
            )
            buffer.frameLength = frameCount
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for (channelIndex, frequency) in frequencies.enumerated() {
                for frame in 0..<Int(frameCount) {
                    samples[frame * frequencies.count + channelIndex] = Float(
                        sin(2 * Double.pi * frequency * Double(frame) / sampleRate) * 0.2
                    )
                }
            }
            try file.write(from: buffer)
        }
    }

    private func exportPassthrough(
        sources: [URL],
        destination: URL,
        fileType: AVFileType
    ) async throws {
        let composition = try await makeComposition(sources: sources)
        let exporter = try XCTUnwrap(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        )
        try await exporter.export(to: destination, as: fileType)
    }

    private func exportAppleM4A(
        sources: [URL],
        destination: URL
    ) async throws {
        let composition = try await makeComposition(sources: sources)
        let exporter = try XCTUnwrap(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        )
        try await exporter.export(to: destination, as: .m4a)
    }

    private func makeComposition(sources: [URL]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        for sourceURL in sources {
            let asset = AVURLAsset(url: sourceURL)
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            let sourceTrack = try XCTUnwrap(sourceTracks.first)
            let duration = try await asset.load(.duration)
            let destinationTrack = try XCTUnwrap(
                composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            )
            try destinationTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
        }
        return composition
    }

    private func rootMeanSquare(_ samples: [Float]) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}
