import Foundation

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

public struct MeetingEndDetectionState: Sendable {
    public private(set) var hasDetectedMeetingWindow = false
    private var missingSince: Date?

    public init() {}

    public mutating func observe(
        hasMeetingWindow: Bool,
        audioLevel: Float,
        at date: Date = Date(),
        gracePeriod: TimeInterval = 30
    ) -> Bool {
        if hasMeetingWindow {
            hasDetectedMeetingWindow = true
            missingSince = nil
            return false
        }

        guard hasDetectedMeetingWindow else { return false }

        if audioLevel > 0.06 {
            missingSince = nil
            return false
        }

        guard let missingSince else {
            self.missingSince = date
            return false
        }

        return date.timeIntervalSince(missingSince) >= gracePeriod
    }
}
