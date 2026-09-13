import Foundation

/// Crash-safe timing metadata for one raw audio segment.
///
/// The two capture APIs do not necessarily start at the same instant. Their
/// monotonic start values are persisted so recovery can rebuild the original
/// timeline after a relaunch instead of incorrectly placing both tracks at t=0.
struct AudioCaptureRecoveryManifest: Codable, Equatable, Sendable {
    struct SourceOffsets: Equatable, Sendable {
        let system: TimeInterval
        let microphone: TimeInterval
    }

    enum Phase: String, Codable, Sendable {
        case preparing
        case recording
        case stopped
        case finalized
    }

    static let currentVersion = 1

    let version: Int
    let outputFileName: String
    let captureStartedAt: Date
    let preparationStartedAtUptime: TimeInterval
    var microphoneStartedAtUptime: TimeInterval?
    var systemStartedAtUptime: TimeInterval?
    var lastObservedAt: Date
    var observedDuration: TimeInterval
    var stoppedAtUptime: TimeInterval?
    var phase: Phase
    var includedSystemAudio: Bool?
    var includedMicrophoneAudio: Bool?
    var finalizationWarning: String?

    init(
        outputFileName: String,
        captureStartedAt: Date = Date(),
        preparationStartedAtUptime: TimeInterval,
        microphoneStartedAtUptime: TimeInterval? = nil,
        systemStartedAtUptime: TimeInterval? = nil,
        lastObservedAt: Date? = nil,
        observedDuration: TimeInterval = 0,
        stoppedAtUptime: TimeInterval? = nil,
        phase: Phase = .preparing,
        includedSystemAudio: Bool? = nil,
        includedMicrophoneAudio: Bool? = nil,
        finalizationWarning: String? = nil
    ) {
        self.version = Self.currentVersion
        self.outputFileName = outputFileName
        self.captureStartedAt = captureStartedAt
        self.preparationStartedAtUptime = preparationStartedAtUptime
        self.microphoneStartedAtUptime = microphoneStartedAtUptime
        self.systemStartedAtUptime = systemStartedAtUptime
        self.lastObservedAt = lastObservedAt ?? captureStartedAt
        self.observedDuration = max(0, observedDuration.isFinite ? observedDuration : 0)
        self.stoppedAtUptime = stoppedAtUptime
        self.phase = phase
        self.includedSystemAudio = includedSystemAudio
        self.includedMicrophoneAudio = includedMicrophoneAudio
        self.finalizationWarning = finalizationWarning
    }

    static func manifestURL(for outputURL: URL) -> URL {
        let stem = outputURL.deletingPathExtension().lastPathComponent
        return outputURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-capture.json")
    }

    static func load(for outputURL: URL) throws -> Self? {
        let url = manifestURL(for: outputURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard manifest.version == currentVersion,
              manifest.outputFileName == outputURL.lastPathComponent,
              manifest.preparationStartedAtUptime.isFinite,
              manifest.observedDuration.isFinite,
              manifest.observedDuration >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    func writeAtomically(for outputURL: URL) throws {
        guard outputFileName == outputURL.lastPathComponent else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let url = Self.manifestURL(for: outputURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    func sourceOffsets(
        includeSystemAudio: Bool,
        includeMicrophoneAudio: Bool
    ) -> SourceOffsets? {
        let includedStarts: [TimeInterval] = [
            includeSystemAudio ? systemStartedAtUptime : nil,
            includeMicrophoneAudio ? microphoneStartedAtUptime : nil
        ].compactMap { $0 }

        let expectedCount = (includeSystemAudio ? 1 : 0) + (includeMicrophoneAudio ? 1 : 0)
        guard expectedCount > 0,
              includedStarts.count == expectedCount,
              includedStarts.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let origin = includedStarts.min() else {
            return nil
        }

        let systemOffset = includeSystemAudio
            ? max(0, (systemStartedAtUptime ?? origin) - origin)
            : 0
        let microphoneOffset = includeMicrophoneAudio
            ? max(0, (microphoneStartedAtUptime ?? origin) - origin)
            : 0

        // A segment spanning more than a day is not a credible meeting. Treat
        // extreme deltas as corrupt metadata instead of exporting hours of
        // accidental silence.
        guard systemOffset <= 86_400, microphoneOffset <= 86_400 else { return nil }
        return SourceOffsets(system: systemOffset, microphone: microphoneOffset)
    }
}
