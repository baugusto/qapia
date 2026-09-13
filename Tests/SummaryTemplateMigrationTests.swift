import Foundation
import XCTest
@testable import QapiaCore

@MainActor
final class SummaryTemplateMigrationTests: XCTestCase {
    func testStoreMigratesExactPreviousStandardBaselineToExecutiveVersion() throws {
        let fileURL = temporaryFileURL()
        let previousBaseline = SummaryTemplate(
            id: SummaryTemplate.standardMeeting.id,
            displayName: SummaryTemplate.standardMeeting.displayName,
            instructions: SummaryTemplate.previousStandardMeetingInstructions,
            sections: SummaryTemplate.standardMeeting.sections,
            isBuiltIn: true
        )
        try persist([previousBaseline], at: fileURL)

        let loaded = try LocalSummaryTemplateStore(fileURL: fileURL).loadTemplates()
        let standard = try XCTUnwrap(loaded.first(where: {
            $0.id == SummaryTemplate.standardMeeting.id
        }))

        XCTAssertEqual(standard.displayName, SummaryTemplate.standardMeeting.displayName)
        XCTAssertEqual(standard.instructions, SummaryTemplate.standardMeeting.instructions)
        XCTAssertEqual(standard.sections, SummaryTemplate.standardMeeting.sections)
    }

    func testStorePreservesUserEditDerivedFromPreviousStandardBaseline() throws {
        let fileURL = temporaryFileURL()
        let editedInstructions = SummaryTemplate.previousStandardMeetingInstructions +
            " Dê prioridade especial aos impactos financeiros."
        let edited = SummaryTemplate(
            id: SummaryTemplate.standardMeeting.id,
            displayName: SummaryTemplate.standardMeeting.displayName,
            instructions: editedInstructions,
            sections: SummaryTemplate.standardMeeting.sections,
            isBuiltIn: true
        )
        try persist([edited], at: fileURL)

        let loaded = try LocalSummaryTemplateStore(fileURL: fileURL).loadTemplates()
        let standard = try XCTUnwrap(loaded.first(where: {
            $0.id == SummaryTemplate.standardMeeting.id
        }))

        XCTAssertEqual(standard.instructions, editedInstructions)
        XCTAssertNotEqual(standard.instructions, SummaryTemplate.standardMeeting.instructions)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("templates.json")
    }

    private func persist(_ templates: [SummaryTemplate], at fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(templates).write(to: fileURL, options: .atomic)
    }
}
