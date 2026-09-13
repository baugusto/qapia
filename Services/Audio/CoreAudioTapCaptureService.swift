@preconcurrency import AVFoundation
import CoreAudio
@preconcurrency import CoreAudioTapSupport
import Darwin
import Foundation
import OSLog

struct AudioTapOperationError: LocalizedError, Sendable {
    let status: OSStatus
    let message: String

    var errorDescription: String? {
        "\(message) (Core Audio: \(Self.statusDescription(status)))"
    }

    var isPermissionDenied: Bool {
        status == kAudioDevicePermissionsError
    }

    var isRecoverableLifecycleFailure: Bool {
        switch status {
        case kAudioHardwareIllegalOperationError,
             kAudioHardwareNotReadyError,
             kAudioHardwareNotRunningError,
             kAudioHardwareBadObjectError,
             kAudioHardwareBadDeviceError,
             kAudioHardwareUnspecifiedError:
            true
        default:
            false
        }
    }

    private static func statusDescription(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
        }
        return String(status)
    }
}

private final class SystemAudioGraph {
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    private var destroyed = false

    init(tapID: AudioObjectID, aggregateDeviceID: AudioObjectID) {
        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    deinit {
        destroy()
    }
}

private struct StoppedAudioCapture: Sendable {
    let systemURL: URL
    let microphoneURL: URL
    let outputURL: URL
    let duration: TimeInterval
    let systemStartedAtUptime: TimeInterval?
    let microphoneStartedAtUptime: TimeInterval?
    let diagnostics: AudioStopDiagnostics
}

private struct AudioStopDiagnostics: Sendable {
    let systemFrameCount: UInt64
    let systemWriteError: OSStatus
    let microphoneWasRecordingAtStop: Bool
    let microphoneFailureDescription: String?

    static let empty = AudioStopDiagnostics(
        systemFrameCount: 0,
        systemWriteError: noErr,
        microphoneWasRecordingAtStop: false,
        microphoneFailureDescription: nil
    )
}

struct AudioFinalizationOutcome: Sendable {
    let fileURL: URL
    let isDegraded: Bool
    let mayDeleteRawSources: Bool
    let degradationReasons: [String]
    let includedSystemAudio: Bool
    let includedMicrophoneAudio: Bool

    var userWarning: String? {
        guard isDegraded else { return nil }
        return "A gravação foi preservada parcialmente. "
            + degradationReasons.joined(separator: " ")
    }
}

private struct AudioSourceInspection: Sendable {
    let duration: TimeInterval?
    let rejectionDescription: String?

    var isValid: Bool {
        duration != nil && rejectionDescription == nil
    }
}

/// Owns every mutable Core Audio and AVFoundation recording object on one
/// serial executor. No recorder or aggregate-device handle crosses actors.
private actor AudioCaptureCoordinator {
    private enum State: Equatable {
        case idle
        case preparing
        case recording
        case stopping
    }

    private static let logger = Logger(subsystem: "br.com.qapia.app", category: "AudioCapture")

    private var systemGraph: SystemAudioGraph?
    private var systemRecorder: CoreAudioTapRecorder?
    private var microphoneRecorder: ExplicitMicrophoneCapture?
    private var systemURL: URL?
    private var microphoneURL: URL?
    private var outputURL: URL?
    private var systemStartedAtUptime: TimeInterval?
    private var microphoneStartedAtUptime: TimeInterval?
    private var startedAt: Date?
    private var captureManifest: AudioCaptureRecoveryManifest?
    private var captureManifestOutputURL: URL?
    private var lastManifestWriteAtUptime: TimeInterval?
    private var state = State.idle

    func startSegment(at fileURL: URL) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        state = .preparing
        let preparationStartedAt = ProcessInfo.processInfo.systemUptime

        let stem = fileURL.deletingPathExtension().lastPathComponent
        let directory = fileURL.deletingLastPathComponent()
        let systemURL = directory.appendingPathComponent("\(stem)-system.caf")
        let microphoneURL = directory.appendingPathComponent("\(stem)-microphone.caf")
        let manifestURL = AudioCaptureRecoveryManifest.manifestURL(for: fileURL)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            [fileURL, systemURL, microphoneURL, manifestURL].forEach {
                try? FileManager.default.removeItem(at: $0)
            }

            captureManifest = AudioCaptureRecoveryManifest(
                outputFileName: fileURL.lastPathComponent,
                preparationStartedAtUptime: preparationStartedAt
            )
            captureManifestOutputURL = fileURL
            lastManifestWriteAtUptime = preparationStartedAt
            try persistCaptureManifest()

            // Start the microphone first so the user's voice is never lost
            // while Core Audio prepares the system-audio graph.
            let microphoneCapture = try await startMicrophoneCapture(outputURL: microphoneURL)
            microphoneRecorder = microphoneCapture.recorder
            microphoneStartedAtUptime = microphoneCapture.startedAtUptime
            captureManifest?.microphoneStartedAtUptime = microphoneCapture.startedAtUptime
            try persistCaptureManifest()
            try await prepareSystemRecordingWithRetry(systemURL: systemURL)
            captureManifest?.systemStartedAtUptime = systemStartedAtUptime
            try persistCaptureManifest()

            guard let microphoneRecorder else {
                throw RecordingError.microphoneUnavailable
            }
            let microphoneSnapshot = await microphoneRecorder.snapshot()
            guard microphoneSnapshot.isRecording else {
                throw RecordingError.captureFailed(
                    microphoneSnapshot.failureDescription
                        ?? "A captura do microfone não permaneceu ativa."
                )
            }

            self.systemURL = systemURL
            self.microphoneURL = microphoneURL
            self.outputURL = fileURL
            startedAt = Date()
            captureManifest?.phase = .recording
            captureManifest?.lastObservedAt = Date()
            captureManifest?.observedDuration = elapsedSinceSourceOrigin(
                atUptime: ProcessInfo.processInfo.systemUptime
            )
            try persistCaptureManifest()
            state = .recording
            let elapsed = ProcessInfo.processInfo.systemUptime - preparationStartedAt
            Self.logger.info("Captura pronta em \(elapsed, format: .fixed(precision: 3)) s")
        } catch {
            _ = await tearDownSegment()
            clearURLs()
            state = .idle
            Self.logger.error("Falha ao preparar captura: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func stopSegment() async throws -> StoppedAudioCapture {
        guard state == .recording,
              let outputURL,
              let systemURL,
              let microphoneURL,
              let startedAt else {
            throw RecordingError.noActiveRecording
        }
        state = .stopping
        let stoppedAtUptime = ProcessInfo.processInfo.systemUptime
        let sourceTimelineOrigin = [
            systemStartedAtUptime,
            microphoneStartedAtUptime
        ].compactMap { $0 }.min()
        // The exported timeline begins at the earliest source (normally the
        // microphone), not when preparation later reports `.recording`.
        let duration = sourceTimelineOrigin.map {
            max(0, stoppedAtUptime - $0)
        } ?? max(0, Date().timeIntervalSince(startedAt))
        captureManifest?.phase = .stopped
        captureManifest?.stoppedAtUptime = stoppedAtUptime
        captureManifest?.lastObservedAt = Date()
        captureManifest?.observedDuration = duration
        try? persistCaptureManifest()
        let diagnostics = await tearDownSegment()
        let stoppedCapture = StoppedAudioCapture(
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL,
            duration: duration,
            systemStartedAtUptime: systemStartedAtUptime,
            microphoneStartedAtUptime: microphoneStartedAtUptime,
            diagnostics: diagnostics
        )
        clearURLs()
        state = .idle
        return stoppedCapture
    }

    func levels() async -> AudioLevelSample {
        guard state == .recording else { return .silence }
        persistCaptureManifestProgressIfNeeded()
        let microphoneSnapshot: ExplicitMicrophoneCaptureSnapshot
        if let microphoneRecorder {
            microphoneSnapshot = await microphoneRecorder.snapshot()
        } else {
            microphoneSnapshot = ExplicitMicrophoneCaptureSnapshot(
                isRecording: false,
                audioLevel: 0,
                duration: 0,
                failureDescription: nil
            )
        }
        return AudioLevelSample(
            microphone: microphoneSnapshot.audioLevel,
            system: systemRecorder?.audioLevel ?? 0
        )
    }

    private func prepareSystemRecordingWithRetry(systemURL: URL) async throws {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                if systemGraph == nil {
                    systemGraph = try Self.makeSystemAudioGraph()
                }
                guard let systemGraph else {
                    throw RecordingError.captureFailed(
                        "Não foi possível preparar o dispositivo de áudio do sistema."
                    )
                }
                let systemCapture = try Self.startSystemRecorder(
                    graph: systemGraph,
                    outputURL: systemURL
                )
                systemRecorder = systemCapture.recorder
                systemStartedAtUptime = systemCapture.startedAtUptime
                return
            } catch let error as AudioTapOperationError
                where error.isRecoverableLifecycleFailure && attempt == 0 {
                lastError = error
                systemRecorder?.stop()
                systemRecorder = nil
                systemStartedAtUptime = nil
                systemGraph?.destroy()
                systemGraph = nil

                // Aggregate-device destruction is asynchronous. A bounded wait
                // prevents a stale device from racing the one permitted rebuild.
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                systemRecorder?.stop()
                systemRecorder = nil
                systemStartedAtUptime = nil
                systemGraph?.destroy()
                systemGraph = nil
                throw error
            }
        }
        systemGraph?.destroy()
        systemGraph = nil
        throw lastError ?? RecordingError.captureFailed(
            "Não foi possível inicializar a captura de áudio."
        )
    }

    private static func makeSystemAudioGraph() throws -> SystemAudioGraph {
        let description = CATapDescription()
        description.name = "QAP.ia — áudio do sistema"
        description.processes = []
        description.isPrivate = true
        description.isExclusive = true
        description.isMixdown = true
        description.isMono = false

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(description, &createdTapID),
            message: "Não foi possível criar a captura do áudio do sistema."
        )

        var createdDeviceID = AudioObjectID(kAudioObjectUnknown)
        do {
            var tapUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.stride)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try check(withUnsafeMutablePointer(to: &tapUID) {
                AudioObjectGetPropertyData(
                    createdTapID,
                    &uidAddress,
                    0,
                    nil,
                    &uidSize,
                    $0
                )
            }, message: "Não foi possível identificar o tap de áudio.")

            let aggregateDescription = CoreAudioTapCaptureService.aggregateDeviceDescription(
                uid: "br.com.qapia.audio.\(UUID().uuidString)",
                tapUID: tapUID as String
            )
            try check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &createdDeviceID
                ),
                message: "Não foi possível preparar o dispositivo de áudio local."
            )

            return SystemAudioGraph(
                tapID: createdTapID,
                aggregateDeviceID: createdDeviceID
            )
        } catch {
            if createdDeviceID != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(createdDeviceID)
            }
            if createdTapID != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(createdTapID)
            }
            throw error
        }
    }

    private static func startSystemRecorder(
        graph: SystemAudioGraph,
        outputURL: URL
    ) throws -> (recorder: CoreAudioTapRecorder, startedAtUptime: TimeInterval) {
        let recorder = CoreAudioTapRecorder(url: outputURL)
        let startedAtUptime = ProcessInfo.processInfo.systemUptime
        do {
            try recorder.start(withDeviceID: graph.aggregateDeviceID)
        } catch {
            let underlying = error as NSError
            throw AudioTapOperationError(
                status: OSStatus(underlying.code),
                message: underlying.localizedDescription
            )
        }

        // Frame callbacks are expected even in absolute silence. This handshake
        // confirms that bytes are being accepted by the file writer without
        // requiring an audible sound to unblock recording.
        let readinessDeadline = ProcessInfo.processInfo.systemUptime + 0.75
        while ProcessInfo.processInfo.systemUptime < readinessDeadline,
              recorder.recordedFrameCount == 0,
              recorder.lastWriteError == noErr {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if recorder.lastWriteError != noErr {
            recorder.stop()
            throw AudioTapOperationError(
                status: recorder.lastWriteError,
                message: "A captura do áudio do sistema não conseguiu gravar as amostras iniciais."
            )
        }
        guard recorder.recordedFrameCount > 0 else {
            recorder.stop()
            throw AudioTapOperationError(
                status: kAudioHardwareNotRunningError,
                message: "A captura do áudio do sistema não começou a gravar amostras."
            )
        }
        return (recorder, startedAtUptime)
    }

    private func startMicrophoneCapture(
        outputURL: URL
    ) async throws -> (
        recorder: ExplicitMicrophoneCapture,
        startedAtUptime: TimeInterval
    ) {
        let hardwareSnapshot: AudioHardwareSnapshot
        do {
            hardwareSnapshot = try CoreAudioDeviceCatalog().snapshot()
        } catch {
            throw RecordingError.captureFailed(error.localizedDescription)
        }
        let selection = AudioInputSelectionPolicy.select(from: hardwareSnapshot)
        guard let selectedDevice = selection.device else {
            throw RecordingError.microphoneUnavailable
        }
        if selection.quality == .degradedFallback {
            Self.logger.warning(
                "Não há entrada não Bluetooth disponível; o microfone \(selectedDevice.name, privacy: .public) pode limitar a qualidade da saída Bluetooth."
            )
        } else {
            Self.logger.info(
                "Microfone selecionado privadamente: \(selectedDevice.name, privacy: .public) [\(selection.reason.rawValue, privacy: .public)]"
            )
        }
        let recorder = ExplicitMicrophoneCapture()
        let capture = try await recorder.start(at: outputURL, selection: selection)
        return (recorder, capture.startedAtUptime)
    }

    private func tearDownSegment() async -> AudioStopDiagnostics {
        let frameCount = systemRecorder?.recordedFrameCount ?? 0
        systemRecorder?.stop()
        let writeError = systemRecorder?.lastWriteError ?? noErr
        self.systemRecorder = nil

        let microphoneSnapshot: ExplicitMicrophoneCaptureSnapshot?
        if let microphoneRecorder {
            microphoneSnapshot = await microphoneRecorder.snapshot()
        } else {
            microphoneSnapshot = nil
        }
        let microphoneWasRecordingAtStop = microphoneSnapshot?.isRecording ?? false
        var microphoneFailureDescription = microphoneSnapshot?.failureDescription
        if let microphoneRecorder {
            do {
                let stopped = try await microphoneRecorder.stop()
                microphoneFailureDescription = microphoneFailureDescription
                    ?? stopped.failureDescription
            } catch {
                microphoneFailureDescription = microphoneFailureDescription
                    ?? error.localizedDescription
            }
        }
        self.microphoneRecorder = nil

        // Intentionally retain systemGraph. Reusing the tap and aggregate
        // avoids the documented asynchronous-destruction race on a quick
        // second recording. A stale graph is rebuilt once on the next start.
        return AudioStopDiagnostics(
            systemFrameCount: frameCount,
            systemWriteError: writeError,
            microphoneWasRecordingAtStop: microphoneWasRecordingAtStop,
            microphoneFailureDescription: microphoneFailureDescription
        )
    }

    private func clearURLs() {
        systemURL = nil
        microphoneURL = nil
        outputURL = nil
        systemStartedAtUptime = nil
        microphoneStartedAtUptime = nil
        startedAt = nil
        captureManifest = nil
        captureManifestOutputURL = nil
        lastManifestWriteAtUptime = nil
    }

    private func persistCaptureManifest() throws {
        guard let captureManifest, let captureManifestOutputURL else { return }
        try captureManifest.writeAtomically(for: captureManifestOutputURL)
        lastManifestWriteAtUptime = ProcessInfo.processInfo.systemUptime
    }

    private func persistCaptureManifestProgressIfNeeded() {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        guard nowUptime - (lastManifestWriteAtUptime ?? 0) >= 1 else { return }
        captureManifest?.lastObservedAt = Date()
        captureManifest?.observedDuration = elapsedSinceSourceOrigin(atUptime: nowUptime)
        try? persistCaptureManifest()
    }

    private func elapsedSinceSourceOrigin(atUptime uptime: TimeInterval) -> TimeInterval {
        let origin = [systemStartedAtUptime, microphoneStartedAtUptime]
            .compactMap { $0 }
            .min()
        return origin.map { max(0, uptime - $0) } ?? 0
    }

    private static func check(_ status: OSStatus, message: String) throws {
        guard status == noErr else {
            throw AudioTapOperationError(status: status, message: message)
        }
    }
}

@MainActor
public final class CoreAudioTapCaptureService: AudioCaptureService, AudioLevelProviding {
    private static let logger = Logger(subsystem: "br.com.qapia.app", category: "AudioFinalization")
    private let coordinator = AudioCaptureCoordinator()
    private var levelTask: Task<Void, Never>?
    private var audioLevelHandler: (@Sendable (AudioLevelSample) -> Void)?

    public init() {}

    public func setAudioLevelHandler(_ handler: (@Sendable (AudioLevelSample) -> Void)?) {
        audioLevelHandler = handler
    }

    public func requestPermissions() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecordingError.microphonePermissionDenied
            }
        default:
            throw RecordingError.microphonePermissionDenied
        }
    }

    public func startSegment(at fileURL: URL) async throws {
        try await requestPermissions()
        do {
            try await coordinator.startSegment(at: fileURL)
            startLevelUpdates()
        } catch {
            stopLevelUpdates()
            throw Self.recordingError(for: error)
        }
    }

    public func stopSegment() async throws -> CapturedAudio {
        stopLevelUpdates()
        let stopped = try await coordinator.stopSegment()

        let systemCaptureError: String?
        if stopped.diagnostics.systemWriteError != noErr {
            systemCaptureError = AudioTapOperationError(
                status: stopped.diagnostics.systemWriteError,
                message: "A escrita do áudio do sistema foi interrompida."
            ).localizedDescription
        } else if stopped.diagnostics.systemFrameCount == 0 {
            systemCaptureError = "A captura do áudio do sistema terminou sem gravar amostras."
        } else {
            systemCaptureError = nil
        }

        let microphoneCaptureError = stopped.diagnostics.microphoneFailureDescription
            ?? (stopped.diagnostics.microphoneWasRecordingAtStop
                ? nil
                : "A captura do microfone terminou antes do encerramento da reunião.")

        do {
            let outcome = try await Self.finalizeAudioTracks(
                systemURL: stopped.systemURL,
                microphoneURL: stopped.microphoneURL,
                outputURL: stopped.outputURL,
                systemCaptureError: systemCaptureError,
                microphoneCaptureError: microphoneCaptureError,
                systemStartedAtUptime: stopped.systemStartedAtUptime,
                microphoneStartedAtUptime: stopped.microphoneStartedAtUptime,
                expectedTimelineDuration: stopped.duration
            )

            let finalizationManifestWasPersisted: Bool
            do {
                guard var manifest = try AudioCaptureRecoveryManifest.load(for: stopped.outputURL) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                manifest.phase = .finalized
                manifest.lastObservedAt = Date()
                manifest.observedDuration = stopped.duration
                manifest.includedSystemAudio = outcome.includedSystemAudio
                manifest.includedMicrophoneAudio = outcome.includedMicrophoneAudio
                manifest.finalizationWarning = outcome.userWarning
                try manifest.writeAtomically(for: stopped.outputURL)
                finalizationManifestWasPersisted = true
            } catch {
                finalizationManifestWasPersisted = false
                Self.logger.warning(
                    "Metadados da finalização não puderam ser persistidos; CAFs brutos serão preservados: \(error.localizedDescription, privacy: .public)"
                )
            }

            if outcome.mayDeleteRawSources && finalizationManifestWasPersisted {
                for temporaryURL in [stopped.systemURL, stopped.microphoneURL]
                    where temporaryURL != outcome.fileURL {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
                try? FileManager.default.removeItem(
                    at: AudioCaptureRecoveryManifest.manifestURL(for: stopped.outputURL)
                )
            } else {
                let reasons = outcome.degradationReasons.joined(separator: "; ")
                Self.logger.warning(
                    "CAFs brutos preservados após a finalização. \(reasons, privacy: .public)"
                )
            }
            return CapturedAudio(
                fileURL: outcome.fileURL,
                duration: stopped.duration,
                warning: outcome.userWarning
            )
        } catch {
            Self.logger.error(
                "Falha de combinação; CAFs brutos preservados em \(stopped.systemURL.path, privacy: .public) e \(stopped.microphoneURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw RecordingError.fileWriteFailed(
                "Não foi possível finalizar o segmento de áudio: \(error.localizedDescription)"
            )
        }
    }

    private func startLevelUpdates() {
        stopLevelUpdates()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = await coordinator.levels()
                guard !Task.isCancelled else { return }
                audioLevelHandler?(level)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopLevelUpdates() {
        levelTask?.cancel()
        levelTask = nil
        audioLevelHandler?(.silence)
    }

    static func combineAudioTracks(
        systemURL: URL,
        microphoneURL: URL,
        outputURL: URL,
        systemStartOffset: TimeInterval = 0,
        microphoneStartOffset: TimeInterval = 0,
        includeSystemAudio: Bool = true,
        includeMicrophoneAudio: Bool = true
    ) async throws -> URL {
        let composition = AVMutableComposition()
        var insertedTrackCount = 0
        var rejectedTrackDescriptions: [String] = []
        var validSources: [(url: URL, duration: TimeInterval, endTime: TimeInterval)] = []
        var mixInputParameters: [AVAudioMixInputParameters] = []

        let requestedSources: [(url: URL, offset: TimeInterval)] = [
            (systemURL, systemStartOffset, includeSystemAudio),
            (microphoneURL, microphoneStartOffset, includeMicrophoneAudio)
        ].compactMap { sourceURL, offset, shouldInclude in
            shouldInclude ? (sourceURL, offset) : nil
        }

        for (sourceURL, offset) in requestedSources {
            do {
                let asset = AVURLAsset(url: sourceURL)
                guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                    rejectedTrackDescriptions.append("\(sourceURL.lastPathComponent): sem faixa de áudio")
                    continue
                }

                let duration = try await asset.load(.duration)
                let durationSeconds = CMTimeGetSeconds(duration)
                guard duration.isValid, durationSeconds.isFinite, durationSeconds > 0 else {
                    rejectedTrackDescriptions.append("\(sourceURL.lastPathComponent): faixa vazia")
                    continue
                }
                guard let destinationTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    rejectedTrackDescriptions.append("\(sourceURL.lastPathComponent): não foi possível criar a faixa final")
                    continue
                }

                let safeOffset = offset.isFinite ? max(0, offset) : 0
                try destinationTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: sourceTrack,
                    at: CMTime(
                        seconds: safeOffset,
                        preferredTimescale: 48_000
                    )
                )
                let inputParameters = AVMutableAudioMixInputParameters(track: destinationTrack)
                inputParameters.setVolume(1, at: .zero)
                mixInputParameters.append(inputParameters)
                insertedTrackCount += 1
                validSources.append((
                    sourceURL,
                    durationSeconds,
                    safeOffset + durationSeconds
                ))
            } catch {
                let underlying = error as NSError
                rejectedTrackDescriptions.append(
                    "\(sourceURL.lastPathComponent): \(underlying.domain) \(underlying.code)"
                )
            }
        }

        guard insertedTrackCount > 0 else {
            let details = rejectedTrackDescriptions.joined(separator: "; ")
            throw RecordingError.fileWriteFailed(
                "Nenhuma faixa de áudio com duração válida foi produzida. \(details)"
            )
        }

        // Export to a unique sibling first. Exporting directly over outputURL
        // would destroy the last known-good recording before AVFoundation has
        // proved that the replacement is complete and decodable.
        let temporaryOutputURL = temporaryAudioExportURL(for: outputURL)
        defer { try? FileManager.default.removeItem(at: temporaryOutputURL) }

        if let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = mixInputParameters
            exporter.audioMix = audioMix
            do {
                try await exporter.export(to: temporaryOutputURL, as: .m4a)
                let inspection = await inspectAudioSource(temporaryOutputURL)
                let readableToEnd = await isAudioSourceReadableToEnd(temporaryOutputURL)
                let expectedDuration = validSources.map(\.endTime).max() ?? 0
                if let failure = finalizedAudioValidationFailure(
                    actualDuration: inspection.duration,
                    expectedDuration: expectedDuration,
                    isReadableToEnd: readableToEnd
                ) {
                    rejectedTrackDescriptions.append(failure)
                } else {
                    try atomicallyPromoteValidatedAudio(
                        at: temporaryOutputURL,
                        to: outputURL
                    )
                    return outputURL
                }
            } catch {
                let underlying = error as NSError
                rejectedTrackDescriptions.append(
                    "Falha ao exportar ou promover o arquivo final: \(underlying.domain) \(underlying.code)"
                )
            }
        } else {
            rejectedTrackDescriptions.append(
                "O codificador M4A não está disponível para a composição de áudio."
            )
        }

        // Some macOS audio configurations refuse to export a composition when
        // one of the original inputs is a header-only CAF (for example, a
        // disabled built-in microphone in clamshell mode). Preserve the longest
        // valid source instead of discarding the captured meeting.
        guard validSources.count == 1, let fallback = validSources.first else {
            if validSources.count > 1 {
                let details = rejectedTrackDescriptions.joined(separator: "; ")
                throw RecordingError.fileWriteFailed(
                    "Não foi possível combinar as duas fontes de áudio. Os arquivos de sistema e microfone foram preservados para recuperação. \(details)"
                )
            }
            throw RecordingError.fileWriteFailed("Não foi possível preservar uma faixa de áudio válida.")
        }
        guard await isAudioSourceReadableToEnd(fallback.url) else {
            throw RecordingError.fileWriteFailed(
                "A única faixa de áudio disponível não pôde ser lida integralmente."
            )
        }
        return fallback.url
    }

    static func finalizeAudioTracks(
        systemURL: URL,
        microphoneURL: URL,
        outputURL: URL,
        systemCaptureError: String?,
        microphoneCaptureError: String?,
        systemStartedAtUptime: TimeInterval?,
        microphoneStartedAtUptime: TimeInterval?,
        expectedTimelineDuration: TimeInterval? = nil
    ) async throws -> AudioFinalizationOutcome {
        let systemInspection = await inspectAudioSource(systemURL)
        let microphoneInspection = await inspectAudioSource(microphoneURL)
        var degradationReasons: [String] = []

        let captureTimelineOrigin = [
            systemStartedAtUptime,
            microphoneStartedAtUptime
        ].compactMap { $0 }.min()
        let systemTruncation = truncationDescription(
            sourceName: "Áudio do sistema",
            inspection: systemInspection,
            expectedTimelineDuration: expectedTimelineDuration,
            sourceStartedAtUptime: systemStartedAtUptime,
            timelineOrigin: captureTimelineOrigin
        )
        let microphoneTruncation = truncationDescription(
            sourceName: "Áudio do microfone",
            inspection: microphoneInspection,
            expectedTimelineDuration: expectedTimelineDuration,
            sourceStartedAtUptime: microphoneStartedAtUptime,
            timelineOrigin: captureTimelineOrigin
        )

        if let systemCaptureError {
            degradationReasons.append(systemCaptureError)
        }
        if let microphoneCaptureError {
            degradationReasons.append(microphoneCaptureError)
        }
        if let rejection = systemInspection.rejectionDescription {
            degradationReasons.append("\(systemURL.lastPathComponent): \(rejection)")
        }
        if let rejection = microphoneInspection.rejectionDescription {
            degradationReasons.append("\(microphoneURL.lastPathComponent): \(rejection)")
        }
        if let systemTruncation {
            degradationReasons.append(systemTruncation)
        }
        if let microphoneTruncation {
            degradationReasons.append(microphoneTruncation)
        }

        // A Core Audio writer can report a late close/write error even when the
        // CAF was finalized completely. Drain that source through an asset
        // reader before deciding: keep a fully readable system track (remote
        // speech is irreplaceable), but reject a genuinely incomplete one. The
        // diagnostic remains a degradation reason so both raw files survive.
        let systemIsReadableDespiteWriterError: Bool
        if systemCaptureError != nil, systemInspection.isValid {
            systemIsReadableDespiteWriterError = await isAudioSourceReadableToEnd(systemURL)
        } else {
            systemIsReadableDespiteWriterError = false
        }
        let includeSystemAudio = systemInspection.isValid
            && (systemCaptureError == nil || systemIsReadableDespiteWriterError)
        // A late microphone interruption can leave useful, decodable speech.
        // A material truncation is still reported as degradation, which also
        // keeps both raw sources, but must not discard the recoverable portion
        // of the user's voice from the finalized meeting.
        let includeMicrophoneAudio = microphoneInspection.isValid

        guard includeSystemAudio || includeMicrophoneAudio else {
            let details = degradationReasons.joined(separator: "; ")
            throw RecordingError.fileWriteFailed(
                "Nenhuma fonte de áudio válida pôde ser finalizada. \(details)"
            )
        }

        let includedStarts = [
            includeSystemAudio ? systemStartedAtUptime : nil,
            includeMicrophoneAudio ? microphoneStartedAtUptime : nil
        ].compactMap { $0 }
        let timelineOrigin = includedStarts.min()

        if includeSystemAudio, systemStartedAtUptime == nil {
            degradationReasons.append("Não foi possível determinar o instante inicial do áudio do sistema.")
        }
        if includeMicrophoneAudio, microphoneStartedAtUptime == nil {
            degradationReasons.append("Não foi possível determinar o instante inicial do microfone.")
        }

        let systemOffset = sourceOffset(
            startedAtUptime: systemStartedAtUptime,
            timelineOrigin: timelineOrigin,
            isIncluded: includeSystemAudio
        )
        let microphoneOffset = sourceOffset(
            startedAtUptime: microphoneStartedAtUptime,
            timelineOrigin: timelineOrigin,
            isIncluded: includeMicrophoneAudio
        )

        let finalizedURL = try await combineAudioTracks(
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL,
            systemStartOffset: systemOffset,
            microphoneStartOffset: microphoneOffset,
            includeSystemAudio: includeSystemAudio,
            includeMicrophoneAudio: includeMicrophoneAudio
        )

        let isDegraded = !degradationReasons.isEmpty
            || !includeSystemAudio
            || !includeMicrophoneAudio
        return AudioFinalizationOutcome(
            fileURL: finalizedURL,
            isDegraded: isDegraded,
            mayDeleteRawSources: !isDegraded && finalizedURL == outputURL,
            degradationReasons: degradationReasons,
            includedSystemAudio: includeSystemAudio,
            includedMicrophoneAudio: includeMicrophoneAudio
        )
    }

    private static func inspectAudioSource(_ sourceURL: URL) async -> AudioSourceInspection {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return AudioSourceInspection(duration: nil, rejectionDescription: "arquivo não encontrado")
        }
        do {
            let asset = AVURLAsset(url: sourceURL)
            guard try await asset.loadTracks(withMediaType: .audio).first != nil else {
                return AudioSourceInspection(duration: nil, rejectionDescription: "sem faixa de áudio")
            }
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard duration.isValid, seconds.isFinite, seconds > 0 else {
                return AudioSourceInspection(duration: nil, rejectionDescription: "faixa vazia")
            }
            return AudioSourceInspection(duration: seconds, rejectionDescription: nil)
        } catch {
            let underlying = error as NSError
            return AudioSourceInspection(
                duration: nil,
                rejectionDescription: "\(underlying.domain) \(underlying.code)"
            )
        }
    }

    static func finalizedAudioValidationFailure(
        actualDuration: TimeInterval?,
        expectedDuration: TimeInterval,
        isReadableToEnd: Bool
    ) -> String? {
        guard isReadableToEnd else {
            return "A faixa final não pôde ser lida até o fim."
        }
        guard let actualDuration,
              actualDuration.isFinite,
              actualDuration > 0 else {
            return "A faixa final está vazia ou possui duração inválida."
        }
        guard expectedDuration.isFinite, expectedDuration > 0 else {
            return nil
        }

        // Export/container rounding is normally a few milliseconds. This
        // allowance tolerates that rounding without accepting a materially
        // shorter file as a successful finalization.
        let tolerance = min(1, max(0.15, expectedDuration * 0.05))
        guard actualDuration + tolerance < expectedDuration else { return nil }
        return String(
            format: "A faixa final tem %.2f s, mas deveria preservar aproximadamente %.2f s.",
            actualDuration,
            expectedDuration
        )
    }

    /// Replaces the destination in one filesystem operation. Because the
    /// candidate is always created in the same directory, POSIX `rename`
    /// provides an atomic commit: on failure the existing destination remains
    /// untouched; on success readers see either the old or the new complete
    /// file, never an intermediate export.
    static func atomicallyPromoteValidatedAudio(
        at temporaryURL: URL,
        to outputURL: URL
    ) throws {
        var renameResult: Int32?
        temporaryURL.withUnsafeFileSystemRepresentation { temporaryPath in
            outputURL.withUnsafeFileSystemRepresentation { outputPath in
                guard let temporaryPath, let outputPath else { return }
                renameResult = Darwin.rename(temporaryPath, outputPath)
            }
        }

        guard let renameResult else {
            throw RecordingError.fileWriteFailed(
                "Não foi possível representar o caminho do arquivo final."
            )
        }
        guard renameResult == 0 else {
            let renameError = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            throw RecordingError.fileWriteFailed(
                "Não foi possível promover o áudio validado sem perder a versão anterior: \(renameError.localizedDescription)"
            )
        }
    }

    private static func temporaryAudioExportURL(for outputURL: URL) -> URL {
        outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputURL.deletingPathExtension().lastPathComponent)-qapia-\(UUID().uuidString)"
            )
            .appendingPathExtension("m4a")
    }

    nonisolated private static func isAudioSourceReadableToEnd(_ sourceURL: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let asset = AVURLAsset(url: sourceURL)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    return false
                }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { return false }
                reader.add(output)
                guard reader.startReading() else { return false }

                var sampleCount = 0
                while let buffer = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    sampleCount += CMSampleBufferGetNumSamples(buffer)
                }
                return sampleCount > 0 && reader.status == .completed
            } catch {
                return false
            }
        }.value
    }

    private static func truncationDescription(
        sourceName: String,
        inspection: AudioSourceInspection,
        expectedTimelineDuration: TimeInterval?,
        sourceStartedAtUptime: TimeInterval?,
        timelineOrigin: TimeInterval?
    ) -> String? {
        guard let actualDuration = inspection.duration,
              let expectedTimelineDuration,
              let sourceStartedAtUptime,
              let timelineOrigin,
              actualDuration.isFinite,
              expectedTimelineDuration.isFinite,
              sourceStartedAtUptime.isFinite,
              timelineOrigin.isFinite else {
            return nil
        }

        // Compare end positions on the shared monotonic timeline. Subtracting
        // the legitimate startup offset prevents the mic pre-roll from making
        // a healthy, later-starting system track look truncated.
        let sourceStartOffset = max(0, sourceStartedAtUptime - timelineOrigin)
        let expectedSourceDuration = max(0, expectedTimelineDuration - sourceStartOffset)
        guard expectedSourceDuration >= 3 else { return nil }

        // File closing and hardware buffers can differ by a fraction of a
        // second. Permit at least one second and up to 8% (capped at five) so
        // only material freezes are classified as truncation.
        let tolerance = max(1, min(5, expectedSourceDuration * 0.08))
        guard actualDuration + tolerance < expectedSourceDuration else { return nil }
        return String(
            format: "%@ com faixa truncada: %.2f s gravados de aproximadamente %.2f s esperados.",
            sourceName,
            actualDuration,
            expectedSourceDuration
        )
    }

    private static func sourceOffset(
        startedAtUptime: TimeInterval?,
        timelineOrigin: TimeInterval?,
        isIncluded: Bool
    ) -> TimeInterval {
        guard isIncluded,
              let startedAtUptime,
              let timelineOrigin,
              startedAtUptime.isFinite,
              timelineOrigin.isFinite else {
            return 0
        }
        return max(0, startedAtUptime - timelineOrigin)
    }

    nonisolated private static func check(_ status: OSStatus, message: String) throws {
        guard status == noErr else {
            throw AudioTapOperationError(status: status, message: message)
        }
    }

    nonisolated static func aggregateDeviceDescription(
        uid: String,
        tapUID: String? = nil
    ) -> [String: Any] {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "QAP.ia Audio",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true
        ]
        if let tapUID {
            description[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: tapUID
            ]]
        }
        return description
    }

    nonisolated static func recordingError(for error: Error) -> RecordingError {
        if let recordingError = error as? RecordingError {
            return recordingError
        }
        if let tapError = error as? AudioTapOperationError {
            if tapError.isPermissionDenied {
                return .systemAudioPermissionDenied
            }
            return .captureFailed(tapError.localizedDescription)
        }
        return .captureFailed(error.localizedDescription)
    }
}
