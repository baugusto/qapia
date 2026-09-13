import AVFoundation
@testable import QapiaCore
import XCTest

final class ExplicitMicrophoneCaptureTests: XCTestCase {
    func testBluetoothDefaultInputUsesBuiltInMicrophone() {
        let builtIn = device(id: 1, name: "Microfone do MacBook", transport: .builtIn, inputs: 1)
        let headset = device(
            id: 2,
            name: "Fone Bluetooth",
            transport: .bluetooth,
            inputs: 1,
            outputs: 2
        )
        let snapshot = AudioHardwareSnapshot(
            devices: [builtIn, headset],
            defaultInputDeviceID: headset.deviceID,
            defaultOutputDeviceID: headset.deviceID
        )

        let selection = AudioInputSelectionPolicy.select(from: snapshot)

        XCTAssertEqual(selection.device, builtIn)
        XCTAssertEqual(selection.quality, .preferred)
        XCTAssertEqual(selection.reason, .replacedBluetoothInputWithBuiltIn)
    }

    func testBluetoothLEDefaultInputUsesBuiltInMicrophone() {
        let builtIn = device(id: 1, name: "Microfone interno", transport: .builtIn, inputs: 1)
        let headset = device(
            id: 2,
            name: "Fone BLE",
            transport: .bluetoothLE,
            inputs: 1,
            outputs: 2
        )
        let snapshot = AudioHardwareSnapshot(
            devices: [headset, builtIn],
            defaultInputDeviceID: headset.deviceID,
            defaultOutputDeviceID: headset.deviceID
        )

        let selection = AudioInputSelectionPolicy.select(from: snapshot)

        XCTAssertEqual(selection.device, builtIn)
        XCTAssertEqual(selection.reason, .replacedBluetoothInputWithBuiltIn)
    }

    func testUSBDefaultInputIsPreservedWithBluetoothOutput() {
        let builtIn = device(id: 1, name: "Microfone interno", transport: .builtIn, inputs: 1)
        let usb = device(id: 2, name: "Microfone USB", transport: .usb, inputs: 2)
        let headset = device(id: 3, name: "AirPods", transport: .bluetooth, outputs: 2)
        let snapshot = AudioHardwareSnapshot(
            devices: [builtIn, usb, headset],
            defaultInputDeviceID: usb.deviceID,
            defaultOutputDeviceID: headset.deviceID
        )

        let selection = AudioInputSelectionPolicy.select(from: snapshot)

        XCTAssertEqual(selection.device, usb)
        XCTAssertEqual(selection.quality, .preferred)
        XCTAssertEqual(selection.reason, .preservedNonBluetoothDefault)
    }

    func testNonBluetoothDefaultInputIsPreserved() {
        let builtIn = device(id: 1, name: "Microfone interno", transport: .builtIn, inputs: 1)
        let output = device(id: 2, name: "Alto-falantes", transport: .builtIn, outputs: 2)
        let snapshot = AudioHardwareSnapshot(
            devices: [builtIn, output],
            defaultInputDeviceID: builtIn.deviceID,
            defaultOutputDeviceID: output.deviceID
        )

        let selection = AudioInputSelectionPolicy.select(from: snapshot)

        XCTAssertEqual(selection.device, builtIn)
        XCTAssertEqual(selection.reason, .preservedNonBluetoothDefault)
    }

    func testBluetoothInputIsPreservedWhenOutputIsNotBluetooth() {
        let headsetMicrophone = device(
            id: 1,
            name: "Microfone Bluetooth",
            transport: .bluetooth,
            inputs: 1
        )
        let speakers = device(
            id: 2,
            name: "Alto-falantes internos",
            transport: .builtIn,
            outputs: 2
        )
        let builtInMicrophone = device(
            id: 3,
            name: "Microfone interno",
            transport: .builtIn,
            inputs: 1
        )
        let snapshot = AudioHardwareSnapshot(
            devices: [headsetMicrophone, speakers, builtInMicrophone],
            defaultInputDeviceID: headsetMicrophone.deviceID,
            defaultOutputDeviceID: speakers.deviceID
        )

        let selection = AudioInputSelectionPolicy.select(from: snapshot)

        XCTAssertEqual(selection.device, headsetMicrophone)
        XCTAssertEqual(selection.quality, .preferred)
        XCTAssertEqual(selection.reason, .preservedDefaultOutsideBluetoothDuplex)
    }

    func testBluetoothOutputWithoutDefaultInputSelectsBuiltInMicrophone() {
        let builtIn = device(id: 1, name: "Microfone interno", transport: .builtIn, inputs: 1)
        let headset = device(id: 2, name: "Headset", transport: .bluetooth, outputs: 2)
        let snapshot = AudioHardwareSnapshot(
            devices: [builtIn, headset],
            defaultInputDeviceID: nil,
            defaultOutputDeviceID: headset.deviceID
        )

        let selection = AudioInputSelectionPolicy.select(from: snapshot)

        XCTAssertEqual(selection.device, builtIn)
        XCTAssertEqual(selection.reason, .selectedBuiltInForBluetoothOutput)
    }

    func testBluetoothInputIsDegradedFallbackWhenBuiltInIsUnavailable() {
        let headset = device(
            id: 2,
            name: "Headset",
            transport: .bluetooth,
            inputs: 1,
            outputs: 2
        )
        let snapshot = AudioHardwareSnapshot(
            devices: [headset],
            defaultInputDeviceID: headset.deviceID,
            defaultOutputDeviceID: headset.deviceID
        )

        let selection = AudioInputSelectionPolicy.select(from: snapshot)

        XCTAssertEqual(selection.device, headset)
        XCTAssertEqual(selection.quality, .degradedFallback)
        XCTAssertEqual(selection.reason, .bluetoothFallbackWithoutBuiltIn)
    }

    func testDeadDefaultInputIsNotSelected() {
        let deadUSB = device(
            id: 1,
            name: "USB desconectado",
            transport: .usb,
            inputs: 1,
            isAlive: false
        )
        let builtIn = device(id: 2, name: "Microfone interno", transport: .builtIn, inputs: 1)
        let snapshot = AudioHardwareSnapshot(
            devices: [deadUSB, builtIn],
            defaultInputDeviceID: deadUSB.deviceID,
            defaultOutputDeviceID: nil
        )

        let selection = AudioInputSelectionPolicy.select(from: snapshot)

        XCTAssertEqual(selection.device, builtIn)
        XCTAssertEqual(selection.reason, .selectedBuiltInFallback)
    }

    func testMissingInputsReportsUnavailable() {
        let speakers = device(id: 1, name: "Alto-falantes", transport: .builtIn, outputs: 2)
        let snapshot = AudioHardwareSnapshot(
            devices: [speakers],
            defaultInputDeviceID: nil,
            defaultOutputDeviceID: speakers.deviceID
        )

        let selection = AudioInputSelectionPolicy.select(from: snapshot)

        XCTAssertNil(selection.device)
        XCTAssertEqual(selection.quality, .unavailable)
        XCTAssertEqual(selection.reason, .noInputAvailable)
    }

    func testConnectedBluetoothDuplexSelectsNonBluetoothInputWithoutChangingSystemDefault() throws {
        let before = try CoreAudioDeviceCatalog().snapshot()
        guard before.defaultOutput?.transport.isBluetooth == true,
              before.defaultInput?.transport.isBluetooth == true else {
            throw XCTSkip("Nenhuma rota Bluetooth duplex está ativa neste Mac.")
        }
        guard before.devices.contains(where: {
            $0.isUsableInput && !$0.transport.isBluetooth
        }) else {
            throw XCTSkip("Nenhuma entrada não Bluetooth está disponível neste Mac.")
        }

        let selection = AudioInputSelectionPolicy.select(from: before)
        let after = try CoreAudioDeviceCatalog().snapshot()

        XCTAssertEqual(selection.quality, .preferred)
        XCTAssertEqual(selection.device?.transport, .builtIn)
        XCTAssertEqual(selection.reason, .replacedBluetoothInputWithBuiltIn)
        XCTAssertEqual(after.defaultInputDeviceID, before.defaultInputDeviceID)
        XCTAssertEqual(after.defaultOutputDeviceID, before.defaultOutputDeviceID)
    }

    func testNativeSixteenAndTwentyFourKilohertzCAFsRemainFinalizableAndDecodable() async throws {
        for sampleRate in [16_000.0, 24_000.0] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("qapia-native-mic-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let systemURL = directory.appendingPathComponent("missing-system.caf")
            let microphoneURL = directory.appendingPathComponent("microphone-\(Int(sampleRate)).caf")
            let outputURL = directory.appendingPathComponent("meeting.m4a")
            try writeToneCAF(to: microphoneURL, sampleRate: sampleRate, duration: 0.6)

            let nativeFile = try AVAudioFile(forReading: microphoneURL)
            XCTAssertEqual(nativeFile.processingFormat.sampleRate, sampleRate, accuracy: 0.1)
            XCTAssertEqual(nativeFile.processingFormat.channelCount, 1)

            let outcome = try await CoreAudioTapCaptureService.finalizeAudioTracks(
                systemURL: systemURL,
                microphoneURL: microphoneURL,
                outputURL: outputURL,
                systemCaptureError: "Áudio do sistema indisponível no cenário de teste.",
                microphoneCaptureError: nil,
                systemStartedAtUptime: nil,
                microphoneStartedAtUptime: 10,
                expectedTimelineDuration: 0.6
            )

            XCTAssertTrue(outcome.includedMicrophoneAudio)
            XCTAssertFalse(outcome.includedSystemAudio)
            XCTAssertEqual(outcome.fileURL, outputURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
            try assertAudioCanBeDecodedToEnd(at: outputURL)
        }
    }

    private func device(
        id: AudioObjectID,
        name: String,
        transport: AudioHardwareTransport,
        inputs: UInt32 = 0,
        outputs: UInt32 = 0,
        isAlive: Bool = true
    ) -> AudioHardwareDeviceSnapshot {
        AudioHardwareDeviceSnapshot(
            deviceID: id,
            uniqueID: "device-\(id)",
            name: name,
            transport: transport,
            inputChannelCount: inputs,
            outputChannelCount: outputs,
            isAlive: isAlive
        )
    }

    private func writeToneCAF(
        to url: URL,
        sampleRate: Double,
        duration: TimeInterval
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Formato PCM inválido")
            return
        }
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            XCTFail("Buffer PCM inválido")
            return
        }
        buffer.frameLength = frameCount
        let angularStep = (2.0 * Double.pi * 440.0) / sampleRate
        for frame in 0..<Int(frameCount) {
            let phase = angularStep * Double(frame)
            channel[frame] = Float(0.22 * sin(phase))
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func assertAudioCanBeDecodedToEnd(at url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        let capacity = AVAudioFrameCount(min(max(file.length, 1), 8_192))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: capacity
        ) else {
            XCTFail("Não foi possível criar o buffer de leitura")
            return
        }

        var decodedFrames: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            decodedFrames += AVAudioFramePosition(buffer.frameLength)
        }
        XCTAssertGreaterThan(decodedFrames, 0)
        XCTAssertEqual(file.framePosition, file.length)
    }
}
