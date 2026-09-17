import Foundation

@MainActor
public protocol SummaryTemplateStore: AnyObject {
    func loadTemplates() throws -> [SummaryTemplate]
    func saveTemplates(_ templates: [SummaryTemplate]) throws
}

@MainActor
public final class LocalSummaryTemplateStore: SummaryTemplateStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    public func loadTemplates() throws -> [SummaryTemplate] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SummaryTemplate.allCases
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([SummaryTemplate].self, from: data)
            return mergeBuiltIns(into: decoded)
        } catch {
            throw SummaryTemplateStoreError.unavailable(error.localizedDescription)
        }
    }

    public func saveTemplates(_ templates: [SummaryTemplate]) throws {
        do {
            let validated = try templates.map { try $0.validated() }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(validated).write(to: fileURL, options: .atomic)
        } catch let error as SummaryTemplateValidationError {
            throw error
        } catch {
            throw SummaryTemplateStoreError.unavailable(error.localizedDescription)
        }
    }

    private func mergeBuiltIns(into stored: [SummaryTemplate]) -> [SummaryTemplate] {
        let legacyBuiltInIDs: Set<String> = ["general", "product-discovery", "refinement", "daily"]
        let builtInIDs = Set(SummaryTemplate.allCases.map(\.id))
        let migratableStandardBaselines: Set<String> = [
            SummaryTemplate.legacyStandardMeetingInstructions,
            SummaryTemplate.previousStandardMeetingInstructions
        ]
        var normalized = stored.compactMap { template -> SummaryTemplate? in
            guard !legacyBuiltInIDs.contains(template.id) else { return nil }
            if template.id == SummaryTemplate.standardMeeting.id,
               template.displayName == SummaryTemplate.standardMeeting.displayName,
               template.sections == SummaryTemplate.standardMeeting.sections,
               migratableStandardBaselines.contains(template.instructions) {
                return .standardMeeting
            }
            let copy = SummaryTemplate(
                id: template.id,
                displayName: template.displayName,
                instructions: template.instructions,
                sections: template.sections,
                sectionSubtopics: template.sectionSubtopics,
                customStructure: template.customStructure,
                isBuiltIn: builtInIDs.contains(template.id)
            )
            return try? copy.validated()
        }

        for template in SummaryTemplate.allCases where !normalized.contains(where: { $0.id == template.id }) {
            normalized.append(template)
        }
        if let standardIndex = normalized.firstIndex(where: {
            $0.id == SummaryTemplate.standardMeeting.id
        }), standardIndex != normalized.startIndex {
            normalized.insert(normalized.remove(at: standardIndex), at: normalized.startIndex)
        }
        return normalized
    }

    private static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Qapia/Templates", isDirectory: true)
            .appendingPathComponent("templates.json", isDirectory: false)
    }
}

@MainActor
public final class MemorySummaryTemplateStore: SummaryTemplateStore {
    public private(set) var templates: [SummaryTemplate]

    public init(templates: [SummaryTemplate] = SummaryTemplate.allCases) {
        self.templates = templates
    }

    public func loadTemplates() throws -> [SummaryTemplate] {
        templates
    }

    public func saveTemplates(_ templates: [SummaryTemplate]) throws {
        self.templates = try templates.map { try $0.validated() }
    }
}

public enum SummaryTemplateStoreError: LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            "Não foi possível acessar os templates locais: \(message)"
        }
    }
}
