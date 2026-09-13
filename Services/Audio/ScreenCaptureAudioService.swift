@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import Foundation

@MainActor
public final class ScreenCaptureAudioService: NSObject, AudioCaptureService, AudioLevelProviding {
    private var stream: SCStream?
    private var coordinator: CaptureCoordinator?
    private var audioLevelHandler: (@Sendable (AudioLevelSample) -> Void)?

    public override init() {}

    public func setAudioLevelHandler(_ handler: (@Sendable (AudioLevelSample) -> Void)?) {
        audioLevelHandler = handler
    }

    public func requestPermissions() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecordingError.microphonePermissionDenied
            }
        default:
            throw RecordingError.microphonePermissionDenied
        }
    }

    public func startSegment(at fileURL: URL) async throws {
        guard stream == nil else { throw RecordingError.alreadyRecording }
        try await requestPermissions()

        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = shareableContent.displays.first else {
                throw RecordingError.captureFailed("Nenhuma tela disponível para capturar o áudio do sistema.")
            }

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.captureMicrophone = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.width = display.width
            configuration.height = display.height

            let coordinator = try CaptureCoordinator(
                fileURL: fileURL,
                audioLevelHandler: audioLevelHandler
            )
            let stream = SCStream(
                filter: SCContentFilter(display: display, excludingWindows: []),
                configuration: configuration,
                delegate: coordinator
            )
            try stream.addStreamOutput(
                coordinator,
                type: .audio,
                sampleHandlerQueue: coordinator.sampleQueue
            )
            try stream.addStreamOutput(
                coordinator,
                type: .microphone,
                sampleHandlerQueue: coordinator.sampleQueue
            )
            try await stream.startCapture()

            self.coordinator = coordinator
            self.stream = stream
        } catch let error as RecordingError {
            throw error
        } catch {
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain,
               nsError.code == SCStreamError.Code.userDeclined.rawValue {
                throw RecordingError.systemAudioPermissionDenied
            }
            throw RecordingError.captureFailed("Não foi possível iniciar a captura de áudio: \(error.localizedDescription)")
        }
    }

    public func stopSegment() async throws -> CapturedAudio {
        guard let stream, let coordinator else { throw RecordingError.noActiveRecording }
        self.stream = nil
        self.coordinator = nil
        audioLevelHandler?(.silence)

        do {
            try await stream.stopCapture()
            return try await coordinator.finish()
        } catch let error as RecordingError {
            throw error
        } catch {
            throw RecordingError.fileWriteFailed("Não foi possível salvar o segmento de áudio: \(error.localizedDescription)")
        }
    }
}

private final class CaptureCoordinator: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "br.com.qapia.audio-capture")

    private let writer: SegmentWriter
    private let levelMeter: AudioLevelMeter
    private var streamError: Error?

    init(
        fileURL: URL,
        audioLevelHandler: (@Sendable (AudioLevelSample) -> Void)?
    ) throws {
        self.writer = try SegmentWriter(fileURL: fileURL, queue: sampleQueue)
        self.levelMeter = AudioLevelMeter(handler: audioLevelHandler)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio || outputType == .microphone else { return }
        writer.append(sampleBuffer, fromMicrophone: outputType == .microphone)
        levelMeter.consume(sampleBuffer, fromMicrophone: outputType == .microphone)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error
    }

    func finish() async throws -> CapturedAudio {
        if let streamError {
            throw RecordingError.captureFailed(streamError.localizedDescription)
        }
        return try await writer.finish()
    }
}

private final class AudioLevelMeter: @unchecked Sendable {
    private let handler: (@Sendable (AudioLevelSample) -> Void)?
    private var microphoneLevel: Float = 0
    private var systemLevel: Float = 0
    private var lastEmission: UInt64 = 0
    private let minimumEmissionInterval: UInt64 = 50_000_000

    init(handler: (@Sendable (AudioLevelSample) -> Void)?) {
        self.handler = handler
    }

    func consume(_ sampleBuffer: CMSampleBuffer, fromMicrophone: Bool) {
        let incoming = Self.normalizedLevel(from: sampleBuffer)
        if fromMicrophone {
            microphoneLevel = AudioLevelAnalyzer.smoothed(
                previous: microphoneLevel,
                incoming: incoming
            )
        } else {
            systemLevel = AudioLevelAnalyzer.smoothed(
                previous: systemLevel,
                incoming: incoming
            )
        }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastEmission >= minimumEmissionInterval else { return }
        lastEmission = now
        handler?(AudioLevelSample(
            microphone: microphoneLevel,
            system: systemLevel
        ))
    }

    private static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
            streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            return 0
        }

        let description = streamDescription.pointee
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: length)
        let status = bytes.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: destination.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else { return 0 }

        let flags = description.mFormatFlags
        if flags & kAudioFormatFlagIsFloat != 0, description.mBitsPerChannel == 32 {
            return bytes.withUnsafeBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Float.self)
                return AudioLevelAnalyzer.normalizedLevel(
                    fromRMS: AudioLevelAnalyzer.rootMeanSquare(of: samples)
                )
            }
        }

        if flags & kAudioFormatFlagIsSignedInteger != 0, description.mBitsPerChannel == 16 {
            return bytes.withUnsafeBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self).map {
                    Float($0) / Float(Int16.max)
                }
                return AudioLevelAnalyzer.normalizedLevel(
                    fromRMS: AudioLevelAnalyzer.rootMeanSquare(of: samples)
                )
            }
        }

        return 0
    }
}

private final class SegmentWriter: @unchecked Sendable {
    private let fileURL: URL
    private let queue: DispatchQueue
    private let writer: AVAssetWriter
    private let systemAudioInput: AVAssetWriterInput
    private let microphoneInput: AVAssetWriterInput
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var hasStartedWriting = false

    init(fileURL: URL, queue: DispatchQueue) throws {
        self.fileURL = fileURL
        self.queue = queue
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
        let systemSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let microphoneSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: systemSettings)
        microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: microphoneSettings)
        systemAudioInput.expectsMediaDataInRealTime = true
        microphoneInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(systemAudioInput), writer.canAdd(microphoneInput) else {
            throw RecordingError.fileWriteFailed("Não foi possível preparar o arquivo M4A do segmento.")
        }
        writer.add(systemAudioInput)
        writer.add(microphoneInput)
    }

    func append(_ sampleBuffer: CMSampleBuffer, fromMicrophone: Bool) {
        let input = fromMicrophone ? microphoneInput : systemAudioInput
        if !hasStartedWriting {
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            firstPresentationTime = time
            hasStartedWriting = true
        }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            lastPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }
    }

    func finish() async throws -> CapturedAudio {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard hasStartedWriting else {
                    writer.cancelWriting()
                    continuation.resume(throwing: RecordingError.captureFailed("Nenhum áudio foi recebido durante a gravação."))
                    return
                }

                systemAudioInput.markAsFinished()
                microphoneInput.markAsFinished()
                writer.finishWriting {
                    guard self.writer.status == .completed else {
                        continuation.resume(throwing: RecordingError.fileWriteFailed(
                            self.writer.error?.localizedDescription ?? "Não foi possível finalizar o arquivo M4A."
                        ))
                        return
                    }
                    let duration = self.recordedDuration
                    continuation.resume(returning: CapturedAudio(fileURL: self.fileURL, duration: duration))
                }
            }
        }
    }

    private var recordedDuration: TimeInterval {
        guard let firstPresentationTime, let lastPresentationTime else { return 0 }
        return max(0, CMTimeGetSeconds(lastPresentationTime - firstPresentationTime))
    }
}
