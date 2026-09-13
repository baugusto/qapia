import Foundation
import XCTest
@testable import QapiaCore

final class LegacyTranscriptionVocabularyMigrationTests: XCTestCase {
    func testPreparationRemovesLegacyVocabularyAndRepeatingMigrationIsSafe() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyVocabularyURL = rootURL
            .appendingPathComponent("Qapia/Transcription/vocabulary.json")
        let bundledModelURL = rootURL.appendingPathComponent("model.bin")
        let modelDestinationURL = rootURL.appendingPathComponent("downloaded-model.bin")
        let modelData = Data("model".utf8)

        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: legacyVocabularyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("termo legado".utf8).write(to: legacyVocabularyURL)
        try modelData.write(to: bundledModelURL)

        let modelStore = WhisperModelStore(
            descriptor: WhisperModelDescriptor(
                fileName: "model.bin",
                downloadURL: URL(string: "https://invalid.example/model.bin")!,
                sha1: "1d06a0d76f000e6edd18de492383983feefced4e"
            ),
            destinationURL: modelDestinationURL,
            bundledModelURL: bundledModelURL
        )
        let coordinator = LocalResourcePreparationCoordinator(
            whisperModelStore: modelStore,
            summaryResourcePreparer: PreparedSummaryResources(),
            legacyVocabularyFileURL: legacyVocabularyURL
        )

        try await coordinator.prepare()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyVocabularyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundledModelURL.path))

        try await coordinator.prepare()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyVocabularyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundledModelURL.path))
    }

    func testMigrationNeverRemovesDirectoryAtLegacyFileLocation() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyVocabularyURL = rootURL
            .appendingPathComponent("Qapia/Transcription/vocabulary.json", isDirectory: true)
        let markerURL = legacyVocabularyURL.appendingPathComponent("preservar.txt")

        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: legacyVocabularyURL,
            withIntermediateDirectories: true
        )
        try Data("não remover".utf8).write(to: markerURL)

        let migration = LegacyTranscriptionVocabularyMigration(
            fileURL: legacyVocabularyURL
        )

        XCTAssertEqual(migration.run(), .preservedNonFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyVocabularyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }
}

private struct PreparedSummaryResources: SummaryResourcePreparing {
    func prepare() async throws {}
}
