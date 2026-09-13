@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Transport information kept independent from Core Audio so input selection
/// can be covered by deterministic tests without connected hardware.
public enum AudioHardwareTransport: String, Sendable, Equatable {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case aggregate
    case virtual
    case airPlay
    case hdmi
    case thunderbolt
    case pci
    case displayPort
    case fireWire
    case unknown

    public var isBluetooth: Bool {
        self == .bluetooth || self == .bluetoothLE
    }

    init(coreAudioValue: UInt32) {
        switch coreAudioValue {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        default: self = .unknown
        }
    }
}

public struct AudioHardwareDeviceSnapshot: Sendable, Equatable {
    public let deviceID: AudioObjectID
    public let uniqueID: String
    public let name: String
    public let transport: AudioHardwareTransport
    public let inputChannelCount: UInt32
    public let outputChannelCount: UInt32
    public let isAlive: Bool

    public init(
        deviceID: AudioObjectID,
        uniqueID: String,
        name: String,
        transport: AudioHardwareTransport,
        inputChannelCount: UInt32,
        outputChannelCount: UInt32,
        isAlive: Bool = true
    ) {
        self.deviceID = deviceID
        self.uniqueID = uniqueID
        self.name = name
        self.transport = transport
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.isAlive = isAlive
    }

    public var isUsableInput: Bool {
        isAlive && inputChannelCount > 0
    }
}

public struct AudioHardwareSnapshot: Sendable, Equatable {
    public let devices: [AudioHardwareDeviceSnapshot]
    public let defaultInputDeviceID: AudioObjectID?
    public let defaultOutputDeviceID: AudioObjectID?

    public init(
        devices: [AudioHardwareDeviceSnapshot],
        defaultInputDeviceID: AudioObjectID?,
        defaultOutputDeviceID: AudioObjectID?
    ) {
        self.devices = devices
        self.defaultInputDeviceID = defaultInputDeviceID
        self.defaultOutputDeviceID = defaultOutputDeviceID
    }

    public var defaultInput: AudioHardwareDeviceSnapshot? {
        devices.first { $0.deviceID == defaultInputDeviceID }
    }

    public var defaultOutput: AudioHardwareDeviceSnapshot? {
        devices.first { $0.deviceID == defaultOutputDeviceID }
    }
}

public struct AudioInputSelection: Sendable, Equatable {
    public enum Quality: String, Sendable, Equatable {
        case preferred
        case degradedFallback
        case unavailable
    }

    public enum Reason: String, Sendable, Equatable {
        case preservedNonBluetoothDefault
        case preservedDefaultOutsideBluetoothDuplex
        case replacedBluetoothInputWithBuiltIn
        case selectedBuiltInForBluetoothOutput
        case selectedBuiltInFallback
        case selectedNonBluetoothFallback
        case bluetoothFallbackWithoutBuiltIn
        case noInputAvailable
    }

    public let device: AudioHardwareDeviceSnapshot?
    public let quality: Quality
    public let reason: Reason

    public init(
        device: AudioHardwareDeviceSnapshot?,
        quality: Quality,
        reason: Reason
    ) {
        self.device = device
        self.quality = quality
        self.reason = reason
    }
}

/// Keeps Bluetooth playback in its high-quality output profile by avoiding the
/// headset microphone whenever a non-Bluetooth input is available. A selected
/// USB or other wired default remains untouched because it does not trigger a
/// Bluetooth hands-free profile transition.
public enum AudioInputSelectionPolicy {
    public static func select(from snapshot: AudioHardwareSnapshot) -> AudioInputSelection {
        let inputs = snapshot.devices.filter(\.isUsableInput)
        let defaultInput = snapshot.defaultInput.flatMap { $0.isUsableInput ? $0 : nil }
        let defaultOutputIsBluetooth = snapshot.defaultOutput?.transport.isBluetooth == true

        if let defaultInput, !defaultOutputIsBluetooth {
            return AudioInputSelection(
                device: defaultInput,
                quality: .preferred,
                reason: defaultInput.transport.isBluetooth
                    ? .preservedDefaultOutsideBluetoothDuplex
                    : .preservedNonBluetoothDefault
            )
        }

        if let defaultInput, !defaultInput.transport.isBluetooth {
            return AudioInputSelection(
                device: defaultInput,
                quality: .preferred,
                reason: .preservedNonBluetoothDefault
            )
        }

        let builtIn = inputs.first { $0.transport == .builtIn }
        if let defaultInput, defaultInput.transport.isBluetooth, let builtIn {
            return AudioInputSelection(
                device: builtIn,
                quality: .preferred,
                reason: .replacedBluetoothInputWithBuiltIn
            )
        }

        if defaultInput == nil, defaultOutputIsBluetooth, let builtIn {
            return AudioInputSelection(
                device: builtIn,
                quality: .preferred,
                reason: .selectedBuiltInForBluetoothOutput
            )
        }

        if defaultInput == nil, let builtIn {
            return AudioInputSelection(
                device: builtIn,
                quality: .preferred,
                reason: .selectedBuiltInFallback
            )
        }

        if let nonBluetooth = inputs.first(where: { !$0.transport.isBluetooth }) {
            return AudioInputSelection(
                device: nonBluetooth,
                quality: .preferred,
                reason: .selectedNonBluetoothFallback
            )
        }

        if let bluetooth = defaultInput ?? inputs.first(where: { $0.transport.isBluetooth }) {
            return AudioInputSelection(
                device: bluetooth,
                quality: .degradedFallback,
                reason: .bluetoothFallbackWithoutBuiltIn
            )
        }

        return AudioInputSelection(
            device: nil,
            quality: .unavailable,
            reason: .noInputAvailable
        )
    }
}

public enum CoreAudioDeviceCatalogError: LocalizedError, Sendable, Equatable {
    case propertyUnavailable(selector: AudioObjectPropertySelector, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .propertyUnavailable(selector, status):
            return "Não foi possível consultar os dispositivos de áudio (propriedade \(selector), Core Audio \(status))."
        }
    }
}

/// Read-only Core Audio inventory used before an AVCaptureSession is created.
/// No default device is changed globally.
public struct CoreAudioDeviceCatalog: Sendable {
    public init() {}

    public func snapshot() throws -> AudioHardwareSnapshot {
        let deviceIDs = try Self.deviceIDs()
        let devices = deviceIDs.compactMap(Self.deviceSnapshot)
        return AudioHardwareSnapshot(
            devices: devices,
            defaultInputDeviceID: Self.defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice),
            defaultOutputDeviceID: Self.defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        )
    }

    private static func deviceIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr else {
            throw CoreAudioDeviceCatalogError.propertyUnavailable(
                selector: address.mSelector,
                status: status
            )
        }

        var result = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.stride
        )
        guard !result.isEmpty else { return [] }
        status = result.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        guard status == noErr else {
            throw CoreAudioDeviceCatalogError.propertyUnavailable(
                selector: address.mSelector,
                status: status
            )
        }
        return result
    }

    private static func deviceSnapshot(_ deviceID: AudioObjectID) -> AudioHardwareDeviceSnapshot? {
        guard let uniqueID = stringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID
        ) else {
            return nil
        }
        let name = stringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyName
        ) ?? uniqueID
        let transportValue = uint32Property(
            deviceID: deviceID,
            selector: kAudioDevicePropertyTransportType
        ) ?? 0
        let alive = (uint32Property(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive
        ) ?? 1) != 0

        return AudioHardwareDeviceSnapshot(
            deviceID: deviceID,
            uniqueID: uniqueID,
            name: name,
            transport: AudioHardwareTransport(coreAudioValue: transportValue),
            inputChannelCount: channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput),
            outputChannelCount: channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput),
            isAlive: alive
        )
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private static func stringProperty(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String : nil
    }

    private static func uint32Property(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func channelCount(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &streamsAddress,
            0,
            nil,
            &streamsSize
        ) == noErr else {
            return 0
        }

        var streams = [AudioStreamID](
            repeating: kAudioObjectUnknown,
            count: Int(streamsSize) / MemoryLayout<AudioStreamID>.stride
        )
        guard !streams.isEmpty else { return 0 }
        guard streams.withUnsafeMutableBytes({ bytes in
            AudioObjectGetPropertyData(
                deviceID,
                &streamsAddress,
                0,
                nil,
                &streamsSize,
                bytes.baseAddress!
            )
        }) == noErr else {
            return 0
        }

        return streams.reduce(into: 0) { channelTotal, streamID in
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
            if AudioObjectGetPropertyData(
                streamID,
                &formatAddress,
                0,
                nil,
                &formatSize,
                &format
            ) == noErr {
                channelTotal += format.mChannelsPerFrame
            }
        }
    }
}

public enum ExplicitMicrophoneCaptureError: LocalizedError, Sendable, Equatable {
    case noInputAvailable
    case selectedDeviceUnavailable(String)
    case cannotAddInput(String)
    case cannotAddFileOutput
    case unsupportedCAFOutput
    case failedToStart(String)
    case noActiveRecording
    case failedToFinish(String)

    public var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            return "Nenhum microfone disponível foi encontrado."
        case let .selectedDeviceUnavailable(name):
            return "O microfone selecionado não está mais disponível: \(name)."
        case let .cannotAddInput(name):
            return "Não foi possível usar o microfone \(name)."
        case .cannotAddFileOutput:
            return "Não foi possível preparar o arquivo do microfone."
        case .unsupportedCAFOutput:
            return "A gravação CAF não está disponível neste Mac."
        case let .failedToStart(message):
            return "Não foi possível iniciar o microfone: \(message)"
        case .noActiveRecording:
            return "Não há gravação de microfone em andamento."
        case let .failedToFinish(message):
            return "Não foi possível finalizar o microfone: \(message)"
        }
    }
}

public struct ExplicitMicrophoneCaptureSnapshot: Sendable, Equatable {
    public let isRecording: Bool
    public let audioLevel: Float
    public let duration: TimeInterval
    public let failureDescription: String?

    public init(
        isRecording: Bool,
        audioLevel: Float,
        duration: TimeInterval,
        failureDescription: String?
    ) {
        self.isRecording = isRecording
        self.audioLevel = min(max(audioLevel.isFinite ? audioLevel : 0, 0), 1)
        self.duration = max(duration.isFinite ? duration : 0, 0)
        self.failureDescription = failureDescription
    }
}

public struct ExplicitMicrophoneCaptureStart: Sendable, Equatable {
    public let outputURL: URL
    public let startedAtUptime: TimeInterval
    public let selection: AudioInputSelection
}

public struct ExplicitMicrophoneCaptureStop: Sendable, Equatable {
    public let outputURL: URL
    public let duration: TimeInterval
    public let failureDescription: String?
}

private final class ExplicitMicrophoneCaptureMonitor: NSObject,
    AVCaptureFileOutputRecordingDelegate,
    AVCaptureFileOutputDelegate,
    @unchecked Sendable {
    private let condition = NSCondition()
    private var recordingStarted = false
    private var recordingFinished = false
    private var expectedStop = false
    private var firstFailureDescription: String?

    func markExpectedStop() {
        condition.lock()
        expectedStop = true
        condition.unlock()
    }

    func waitForStart(until deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !recordingStarted, !recordingFinished, firstFailureDescription == nil {
            guard condition.wait(until: deadline) else { break }
        }
        return recordingStarted && firstFailureDescription == nil
    }

    func waitForFinish(until deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !recordingFinished {
            guard condition.wait(until: deadline) else { break }
        }
        return recordingFinished
    }

    func snapshot(
        fileOutputIsRecording: Bool,
        audioLevel: Float,
        duration: TimeInterval
    ) -> ExplicitMicrophoneCaptureSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return ExplicitMicrophoneCaptureSnapshot(
            isRecording: recordingStarted && !recordingFinished && fileOutputIsRecording,
            audioLevel: audioLevel,
            duration: duration,
            failureDescription: firstFailureDescription
        )
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        condition.lock()
        recordingStarted = true
        condition.broadcast()
        condition.unlock()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        condition.lock()
        if let error {
            let underlying = error as NSError
            let successfullyFinished = underlying.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
            if successfullyFinished != true, firstFailureDescription == nil {
                firstFailureDescription = underlying.localizedDescription
            }
        } else if !expectedStop, firstFailureDescription == nil {
            firstFailureDescription = "A captura do microfone terminou antes do encerramento da reunião."
        }
        recordingFinished = true
        condition.broadcast()
        condition.unlock()
    }

    func fileOutputShouldProvideSampleAccurateRecordingStart(
        _ output: AVCaptureFileOutput
    ) -> Bool {
        false
    }
}

/// Records one explicitly selected physical input. All AVCaptureSession
/// mutation runs on a private serial queue; delegate state is lock-protected,
/// so the main actor never owns blocking capture work.
public final class ExplicitMicrophoneCapture: @unchecked Sendable {
    private enum State {
        case idle
        case preparing
        case recording
        case stopping
    }

    private let captureQueue = DispatchQueue(
        label: "br.com.qapia.explicit-microphone.capture",
        qos: .userInitiated
    )
    private let captureQueueKey = DispatchSpecificKey<UInt8>()
    private var state = State.idle
    private var session: AVCaptureSession?
    private var fileOutput: AVCaptureAudioFileOutput?
    private var monitor: ExplicitMicrophoneCaptureMonitor?
    private var outputURL: URL?
    private var startedAtUptime: TimeInterval?

    public init() {
        captureQueue.setSpecific(key: captureQueueKey, value: 1)
    }

    deinit {
        let cleanup = { [self] in
            monitor?.markExpectedStop()
            if fileOutput?.isRecording == true {
                fileOutput?.stopRecording()
            }
            fileOutput?.delegate = nil
            session?.stopRunning()
        }
        if DispatchQueue.getSpecific(key: captureQueueKey) != nil {
            cleanup()
        } else {
            captureQueue.sync(execute: cleanup)
        }
    }

    public func start(
        at outputURL: URL,
        selection: AudioInputSelection
    ) async throws -> ExplicitMicrophoneCaptureStart {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [self] in
                do {
                    let result = try startOnCaptureQueue(at: outputURL, selection: selection)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async throws -> ExplicitMicrophoneCaptureStop {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [self] in
                do {
                    continuation.resume(returning: try stopOnCaptureQueue())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func snapshot() async -> ExplicitMicrophoneCaptureSnapshot {
        await withCheckedContinuation { continuation in
            captureQueue.async { [self] in
                let snapshot: ExplicitMicrophoneCaptureSnapshot
                if let monitor, let fileOutput {
                    snapshot = Self.snapshot(monitor: monitor, fileOutput: fileOutput)
                } else {
                    snapshot = ExplicitMicrophoneCaptureSnapshot(
                        isRecording: false,
                        audioLevel: 0,
                        duration: 0,
                        failureDescription: nil
                    )
                }
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func startOnCaptureQueue(
        at requestedOutputURL: URL,
        selection: AudioInputSelection
    ) throws -> ExplicitMicrophoneCaptureStart {
        guard state == .idle else {
            throw ExplicitMicrophoneCaptureError.failedToStart("já existe uma captura ativa")
        }
        guard let selectedDevice = selection.device else {
            throw ExplicitMicrophoneCaptureError.noInputAvailable
        }
        state = .preparing

        do {
            guard let captureDevice = Self.captureDevice(matching: selectedDevice) else {
                throw ExplicitMicrophoneCaptureError.selectedDeviceUnavailable(selectedDevice.name)
            }
            let input = try AVCaptureDeviceInput(device: captureDevice)
            let session = AVCaptureSession()
            let fileOutput = AVCaptureAudioFileOutput()
            let monitor = ExplicitMicrophoneCaptureMonitor()

            guard AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.caf) else {
                throw ExplicitMicrophoneCaptureError.unsupportedCAFOutput
            }

            session.beginConfiguration()
            var configurationWasCommitted = false
            defer {
                if !configurationWasCommitted {
                    session.commitConfiguration()
                }
            }
            guard session.canAddInput(input) else {
                throw ExplicitMicrophoneCaptureError.cannotAddInput(selectedDevice.name)
            }
            session.addInput(input)
            guard session.canAddOutput(fileOutput) else {
                throw ExplicitMicrophoneCaptureError.cannotAddFileOutput
            }
            session.addOutput(fileOutput)

            // Preserve the microphone's native sample rate in the CAF. The
            // existing finalizer performs any conversion only after capture.
            fileOutput.audioSettings = nil
            fileOutput.delegate = monitor
            session.commitConfiguration()
            configurationWasCommitted = true

            self.session = session
            self.fileOutput = fileOutput
            self.monitor = monitor
            self.outputURL = requestedOutputURL
            try? FileManager.default.removeItem(at: requestedOutputURL)

            session.startRunning()
            guard session.isRunning else {
                throw ExplicitMicrophoneCaptureError.failedToStart("a sessão de captura não iniciou")
            }
            let startUptime = ProcessInfo.processInfo.systemUptime
            fileOutput.startRecording(
                to: requestedOutputURL,
                outputFileType: .caf,
                recordingDelegate: monitor
            )
            guard monitor.waitForStart(until: Date().addingTimeInterval(1.5)) else {
                let failure = Self.snapshot(
                    monitor: monitor,
                    fileOutput: fileOutput
                ).failureDescription ?? "nenhuma amostra foi recebida"
                throw ExplicitMicrophoneCaptureError.failedToStart(failure)
            }

            startedAtUptime = startUptime
            state = .recording
            return ExplicitMicrophoneCaptureStart(
                outputURL: requestedOutputURL,
                startedAtUptime: startUptime,
                selection: selection
            )
        } catch {
            tearDownOnCaptureQueue()
            state = .idle
            throw error
        }
    }

    private func stopOnCaptureQueue() throws -> ExplicitMicrophoneCaptureStop {
        guard state == .recording,
              let session,
              let fileOutput,
              let monitor,
              let outputURL else {
            throw ExplicitMicrophoneCaptureError.noActiveRecording
        }
        state = .stopping
        let stoppedAtUptime = ProcessInfo.processInfo.systemUptime
        monitor.markExpectedStop()
        let outputDuration = CMTimeGetSeconds(fileOutput.recordedDuration)
        if fileOutput.isRecording {
            fileOutput.stopRecording()
        }

        var didFinish = monitor.waitForFinish(until: Date().addingTimeInterval(2))
        if !didFinish {
            session.stopRunning()
            didFinish = monitor.waitForFinish(until: Date().addingTimeInterval(1))
        }
        let snapshot = Self.snapshot(monitor: monitor, fileOutput: fileOutput)
        let elapsed = startedAtUptime.map {
            max(0, stoppedAtUptime - $0)
        } ?? 0
        let duration = max(
            outputDuration.isFinite ? outputDuration : 0,
            snapshot.duration,
            elapsed
        )
        tearDownOnCaptureQueue()
        state = .idle

        if !didFinish {
            throw ExplicitMicrophoneCaptureError.failedToFinish(
                "o arquivo não confirmou a conclusão dentro do prazo"
            )
        }
        return ExplicitMicrophoneCaptureStop(
            outputURL: outputURL,
            duration: duration,
            failureDescription: snapshot.failureDescription
        )
    }

    private func tearDownOnCaptureQueue() {
        monitor?.markExpectedStop()
        if fileOutput?.isRecording == true {
            fileOutput?.stopRecording()
        }
        fileOutput?.delegate = nil
        session?.stopRunning()
        session = nil
        fileOutput = nil
        monitor = nil
        outputURL = nil
        startedAtUptime = nil
    }

    private static func captureDevice(
        matching selectedDevice: AudioHardwareDeviceSnapshot
    ) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.first { $0.uniqueID == selectedDevice.uniqueID }
            ?? discovery.devices.first { $0.localizedName == selectedDevice.name }
    }

    private static func snapshot(
        monitor: ExplicitMicrophoneCaptureMonitor,
        fileOutput: AVCaptureAudioFileOutput
    ) -> ExplicitMicrophoneCaptureSnapshot {
        let powers = fileOutput.connections.flatMap(\.audioChannels).map(\.averagePowerLevel)
        let decibels = powers.filter(\.isFinite).max() ?? -.infinity
        let duration = CMTimeGetSeconds(fileOutput.recordedDuration)
        return monitor.snapshot(
            fileOutputIsRecording: fileOutput.isRecording,
            audioLevel: AudioLevelAnalyzer.normalizedLevel(fromDecibels: decibels),
            duration: duration
        )
    }
}
