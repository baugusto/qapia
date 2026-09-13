import Foundation
import AppKit
import CoreAudio

public enum SupportedMeetingWindowDetector {
    public static func matches(applicationName: String?, windowTitle: String?) -> Bool {
        let application = normalized(applicationName)
        let title = normalized(windowTitle)
        guard !application.isEmpty || !title.isEmpty else { return false }

        let isBrowser = ["chrome", "safari", "firefox", "edge", "arc"]
            .contains { application.contains($0) }

        if title.contains("google meet") || title.contains("meet.google.com") ||
            (isBrowser && title.contains(" meet ")) {
            return true
        }

        let meetingTerms = ["meeting", "reuniao", "call", "chamada", "webinar"]
        let hasMeetingTerm = meetingTerms.contains { title.contains($0) }

        if application.contains("zoom") && hasMeetingTerm {
            return true
        }

        if (application.contains("microsoft teams") || application == "teams") && hasMeetingTerm {
            return true
        }

        if isBrowser && hasMeetingTerm && (title.contains("zoom") || title.contains("microsoft teams")) {
            return true
        }

        return false
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Detects conferencing activity from Core Audio's process objects. This reads
/// only process metadata and whether an audio stream is running; it never
/// enumerates windows, pixels, displays, or screen-capture content.
public enum SupportedMeetingAudioProcessDetector {
    public static func hasActiveMeetingProcess(
        excludingProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        processObjectIDs().contains { objectID in
            guard let processID: pid_t = propertyValue(
                objectID: objectID,
                selector: kAudioProcessPropertyPID,
                initialValue: 0
            ),
            processID != excludingProcessID,
            let isRunning: UInt32 = propertyValue(
                objectID: objectID,
                selector: kAudioProcessPropertyIsRunning,
                initialValue: 0
            ),
            isRunning != 0 else {
                return false
            }

            let bundleIdentifier = processBundleIdentifier(objectID: objectID)
            let applicationName = NSRunningApplication(
                processIdentifier: processID
            )?.localizedName
            let isRunningInput: UInt32 = propertyValue(
                objectID: objectID,
                selector: kAudioProcessPropertyIsRunningInput,
                initialValue: 0
            ) ?? 0
            return isActiveMeetingActivity(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName,
                isRunning: isRunning != 0,
                isRunningInput: isRunningInput != 0
            )
        }
    }

    public static func matches(
        bundleIdentifier: String?,
        applicationName: String?
    ) -> Bool {
        processKind(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName
        ) != nil
    }

    /// Browser output is not, by itself, evidence of a meeting: music or a
    /// video in another tab uses the same Core Audio process. A live browser
    /// input stream is the privacy-preserving signal that a call is using the
    /// microphone. Native conferencing apps keep their existing running-stream
    /// behavior because Zoom and Teams expose dedicated processes.
    public static func isActiveMeetingActivity(
        bundleIdentifier: String?,
        applicationName: String?,
        isRunning: Bool,
        isRunningInput: Bool
    ) -> Bool {
        guard isRunning,
              let kind = processKind(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName
              ) else {
            return false
        }
        switch kind {
        case .nativeConference:
            return true
        case .browser:
            return isRunningInput
        }
    }

    private enum ProcessKind {
        case nativeConference
        case browser
    }

    private static func processKind(
        bundleIdentifier: String?,
        applicationName: String?
    ) -> ProcessKind? {
        let bundle = normalized(bundleIdentifier)
        let name = normalized(applicationName)
        let nativeIdentifiers = [
            "us.zoom",
            "com.microsoft.teams"
        ]
        if nativeIdentifiers.contains(where: { bundle.hasPrefix($0) }) ||
            ["zoom", "teams"].contains(where: { name.contains($0) }) {
            return .nativeConference
        }

        let browserIdentifiers = [
            "com.google.chrome",
            "com.apple.safari",
            "com.apple.webkit.webcontent",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "company.thebrowser.browser",
            "com.brave.browser"
        ]
        if browserIdentifiers.contains(where: { bundle.hasPrefix($0) }) {
            return .browser
        }

        if ["chrome", "safari", "firefox", "edge", "arc", "brave"]
            .contains(where: { name.contains($0) }) {
            return .browser
        }
        return nil
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr,
        dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return []
        }

        var objectIDs = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        let status = objectIDs.withUnsafeMutableBytes { storage in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                storage.baseAddress!
            )
        }
        guard status == noErr else { return [] }
        return objectIDs
    }

    private static func propertyValue<Value>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        initialValue: Value
    ) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = initialValue
        var dataSize = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        return status == noErr ? value : nil
    }

    private static func processBundleIdentifier(objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedValue: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedValue) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        guard status == noErr, let unmanagedValue else { return nil }
        return unmanagedValue.takeRetainedValue() as String
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public struct MeetingEndDetectionState: Sendable {
    public private(set) var hasDetectedMeetingWindow = false
    public private(set) var hasDetectedAudio = false
    private var missingSince: Date?
    private var silenceSince: Date?
    private var scheduledEndSilenceSince: Date?

    public init() {}

    public mutating func observe(
        hasMeetingWindow: Bool,
        audioLevel: Float,
        at date: Date = Date(),
        gracePeriod: TimeInterval = 30,
        scheduledEnd: Date? = nil,
        scheduledEndGracePeriod: TimeInterval = 45,
        silenceFallbackPeriod: TimeInterval = 180
    ) -> Bool {
        let hasAudio = audioLevel > 0.06
        if hasAudio {
            hasDetectedAudio = true
            silenceSince = nil
            scheduledEndSilenceSince = nil
        } else if hasDetectedAudio, silenceSince == nil {
            silenceSince = date
        }

        if hasMeetingWindow {
            hasDetectedMeetingWindow = true
            missingSince = nil
        } else if hasDetectedMeetingWindow {
            // Once a meeting-specific process/input stream was observed, its
            // continuous disappearance is authoritative. Generic system audio
            // may come from an unrelated browser tab and must not keep a
            // finished call alive.
            if let missingSince, date.timeIntervalSince(missingSince) >= gracePeriod {
                return true
            }
            if missingSince == nil { missingSince = date }
        }

        if let scheduledEnd, date >= scheduledEnd, !hasMeetingWindow, !hasAudio {
            if let scheduledEndSilenceSince,
               date.timeIntervalSince(scheduledEndSilenceSince) >= scheduledEndGracePeriod {
                return true
            }
            if scheduledEndSilenceSince == nil { scheduledEndSilenceSince = date }
        }

        if !hasDetectedMeetingWindow,
           let silenceSince,
           date.timeIntervalSince(silenceSince) >= silenceFallbackPeriod {
            return true
        }

        return false
    }
}
