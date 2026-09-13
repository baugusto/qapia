import Foundation
import XCTest
@testable import QapiaCore

final class WhisperAccuracyTests: XCTestCase {
    func testPortugueseProfileUsesInternalSegmentationWithoutPrintingTimestamps() {
        let profile = WhisperDecodingProfile.highFidelityPortuguese
        let parameters = WhisperEngine.parameters(for: profile)

        XCTAssertEqual(profile.languageCode, "pt")
        XCTAssertTrue(profile.generatesSegmentTimestamps)
        XCTAssertFalse(profile.keepsPreviousTextContext)
        XCTAssertEqual(profile.greedyBestOf, 5)
        XCTAssertFalse(parameters.no_timestamps)
        XCTAssertFalse(parameters.single_segment)
        XCTAssertFalse(parameters.token_timestamps)
        XCTAssertFalse(parameters.print_timestamps)
        XCTAssertTrue(parameters.no_context)
        XCTAssertEqual(parameters.greedy.best_of, 5)
    }

    func testAudioContentGateRejectsNoiseFloorButPreservesQuietSpeech() {
        let noiseFloor = Array(repeating: Float(0.0001), count: 16_000 * 2)
        XCTAssertTrue(WhisperAudioContentAnalyzer.isEffectivelySilent(noiseFloor))

        let quietSpeech = (0..<(16_000 * 2)).map { index in
            Float(0.0018 * sin(2 * Double.pi * 220 * Double(index) / 16_000))
        }
        XCTAssertFalse(WhisperAudioContentAnalyzer.isEffectivelySilent(quietSpeech))

        var briefQuietSpeech = noiseFloor
        for index in 8_000..<8_960 {
            briefQuietSpeech[index] = Float(
                0.003 * sin(2 * Double.pi * 220 * Double(index) / 16_000)
            )
        }
        XCTAssertFalse(WhisperAudioContentAnalyzer.isEffectivelySilent(briefQuietSpeech))
    }

    func testIsolatedNonSpeechLabelsAreRemovedWithoutDeletingSpokenContent() {
        XCTAssertEqual(
            WhisperTranscriptSanitizer.removingNonSpeechOnlyResult("[Música]\n[Silêncio]"),
            ""
        )
        XCTAssertEqual(
            WhisperTranscriptSanitizer.removingNonSpeechOnlyResult(
                "A reunião começou.\n[Música]"
            ),
            "A reunião começou."
        )
        XCTAssertEqual(
            WhisperTranscriptSanitizer.removingNonSpeechOnlyResult(
                "A palavra música foi mencionada durante a reunião."
            ),
            "A palavra música foi mencionada durante a reunião."
        )
    }

    func testAudioPreprocessorBoostsQuietSpeechWithoutChangingDurationOrClipping() {
        let quietSpeech = (0..<(16_000 * 2)).map { index in
            Float(0.008 * sin(2 * Double.pi * 220 * Double(index) / 16_000))
        }

        let processed = WhisperAudioPreprocessor.prepare(quietSpeech)

        XCTAssertEqual(processed.count, quietSpeech.count)
        XCTAssertGreaterThan(rms(processed), rms(quietSpeech) * 2)
        XCTAssertLessThanOrEqual(processed.map { abs($0) }.max() ?? 0, 1)
        XCTAssertTrue(processed.allSatisfy(\.isFinite))
    }

    func testAudioTrimmerRemovesOnlySustainedTrailingSilenceAndKeepsSafetyTail() {
        let speech = (0..<(16_000 * 2)).map { index in
            Float(0.02 * sin(2 * Double.pi * 220 * Double(index) / 16_000))
        }
        let longSilence = Array(repeating: Float.zero, count: 16_000 * 2)
        let shortSilence = Array(repeating: Float.zero, count: 16_000 / 2)

        let trimmed = WhisperAudioTrimmer.trimmingTrailingSilence(
            from: speech + longSilence
        )

        XCTAssertGreaterThanOrEqual(trimmed.count, speech.count)
        XCTAssertLessThanOrEqual(trimmed.count, speech.count + 4_320)
        XCTAssertEqual(
            WhisperAudioTrimmer.trimmingTrailingSilence(from: speech + shortSilence).count,
            speech.count + shortSilence.count
        )
    }

    func testAudioTrimmerPreservesVeryQuietSpeech() {
        let quietSpeech = (0..<(16_000 * 2)).map { index in
            Float(0.0018 * sin(2 * Double.pi * 220 * Double(index) / 16_000))
        }

        XCTAssertEqual(
            WhisperAudioTrimmer.trimmingTrailingSilence(from: quietSpeech).count,
            quietSpeech.count
        )
    }

    func testPostprocessorRemovesLongASRRepeatWithoutRewritingRecognizedWords() {
        let introduction = "1, 2, 3, gravando o som, vou falar os nomes para verificar a captura correta."
        let raw = """
        \(introduction)
        Roy Wise, bot maker, Sanaia Lagoas, QAP ia. \(introduction)
        Todas são atividades para a próxima semana.
        """

        let processed = WhisperTranscriptPostprocessor.process(raw)

        XCTAssertTrue(processed.contains("Roy Wise"))
        XCTAssertTrue(processed.contains("bot maker"))
        XCTAssertTrue(processed.contains("Sanaia Lagoas"))
        XCTAssertTrue(processed.contains("QAP ia"))
        XCTAssertEqual(processed.components(separatedBy: introduction).count - 1, 1)
        XCTAssertTrue(processed.contains("Todas são atividades"))
        XCTAssertTrue(processed.contains("QAP ia. Todas são atividades"))
    }

    func testPostprocessorPreservesLegitimateNonOpeningRepetition() {
        let repeated = "esta sequência possui mais de doze palavras e foi realmente repetida pela pessoa durante a reunião"
        let raw = "Abertura curta. \(repeated). Outro assunto. \(repeated). Encerramento."

        XCTAssertEqual(
            WhisperTranscriptPostprocessor.process(raw),
            raw
        )
    }

    func testPostprocessorCollapsesOnlyThreeOrMoreIdenticalPhrasesAtTheTail() {
        let phrase = "o que é um modelo de layout"
        let raw = "A explicação terminou. \(phrase). \(phrase). \(phrase)."

        XCTAssertEqual(
            WhisperTranscriptPostprocessor.process(raw),
            "A explicação terminou. \(phrase)."
        )
        XCTAssertEqual(
            WhisperTranscriptPostprocessor.process(
                "A pessoa repetiu. \(phrase). \(phrase). Encerramento."
            ),
            "A pessoa repetiu. \(phrase). \(phrase). Encerramento."
        )
    }

    func testPostprocessorRemovesLongNearVerbatimOpeningEchoAtTheTail() {
        let raw = """
        1, 2, 3, gravando o som. Vou falar os nomes para poder ver se eu vou contar o que eu tenho que ver.
        A equipe confirmou todas as atividades para a próxima semana.
        A gente vai falar os nomes para poder ver se eu vou contar o que eu tenho que ver.
        """

        XCTAssertEqual(
            WhisperTranscriptPostprocessor.process(raw),
            "1, 2, 3, gravando o som. Vou falar os nomes para poder ver se eu vou contar o que eu tenho que ver.\nA equipe confirmou todas as atividades para a próxima semana."
        )
    }

    func testWhisperUsesCrashSafeCPUInference() {
        XCTAssertFalse(WhisperEngine.contextParameters().use_gpu)
    }

    func testDefaultModelDescriptorIsOfficialMultilingualSmall() {
        XCTAssertEqual(WhisperModelDescriptor.small.fileName, "ggml-small.bin")
        XCTAssertEqual(
            WhisperModelDescriptor.small.downloadURL.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
        )
        XCTAssertEqual(
            WhisperModelDescriptor.small.sha1,
            "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
        )
    }

    func testFailedReplacementDoesNotDeleteExistingModelCache() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = rootURL.appendingPathComponent("ggml-small.bin")
        let invalidBundle = rootURL.appendingPathComponent("invalid-small.bin")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("cache existente".utf8).write(to: destination)
        try Data("bundle inválido".utf8).write(to: invalidBundle)
        let store = WhisperModelStore(
            destinationURL: destination,
            bundledModelURL: invalidBundle
        )

        do {
            _ = try await store.preparedModelURL()
            XCTFail("Era esperada uma falha de integridade.")
        } catch let error as WhisperModelError {
            XCTAssertEqual(error, .integrityCheckFailed)
        }

        XCTAssertEqual(try Data(contentsOf: destination), Data("cache existente".utf8))
    }

    func testStandaloneBundleUsesValidatedEmbeddedModelWhenProvided() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment[
            "QAPIA_BUNDLED_TRANSCRIPTION_MODEL"
        ] else {
            throw XCTSkip("Defina QAPIA_BUNDLED_TRANSCRIPTION_MODEL para validar o pacote standalone.")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("downloaded-model.bin")
        let embeddedURL = URL(fileURLWithPath: modelPath)
        let store = WhisperModelStore(
            destinationURL: destination,
            bundledModelURL: embeddedURL
        )

        let preparedURL = try await store.preparedModelURL()

        XCTAssertEqual(preparedURL.standardizedFileURL, embeddedURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPortugueseAccuracyFixtureMeetsFidelityContractWhenProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["QAPIA_TRANSCRIPTION_FIXTURE"] else {
            throw XCTSkip("Defina QAPIA_TRANSCRIPTION_FIXTURE para validar um áudio real.")
        }

        let minimumWordCount = environment["QAPIA_TRANSCRIPTION_MIN_WORDS"]
            .flatMap(Int.init) ?? 24
        let expectedTerms = environment["QAPIA_TRANSCRIPTION_EXPECTED_TERMS"]?
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let forbiddenTerms = environment["QAPIA_TRANSCRIPTION_FORBIDDEN_TERMS"]?
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        let segment = RecordingSegment(
            meetingID: UUID(),
            sequence: 1,
            fileURL: URL(fileURLWithPath: fixturePath),
            recordedDuration: 0
        )
        let modelStore = environment["QAPIA_TRANSCRIPTION_MODEL"].map {
            WhisperModelStore(
                destinationURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent("ggml-small.bin"),
                bundledModelURL: URL(fileURLWithPath: $0)
            )
        } ?? .shared
        let result = try await WhisperCppService(modelStore: modelStore)
            .transcribeWithDiagnostics(segment: segment)
        let transcript = result.transcript
        let words = transcript.split(whereSeparator: { $0.isWhitespace })

        print("\n=== QAPIA FIDELITY OUTPUT ===\n\(transcript)\n=== END QAPIA FIDELITY OUTPUT ===\n")

        XCTAssertGreaterThanOrEqual(
            words.count,
            minimumWordCount,
            "A transcrição perdeu cobertura do conteúdo falado."
        )

        let normalizedTranscript = normalize(transcript)
        for term in expectedTerms {
            XCTAssertTrue(
                normalizedTranscript.contains(normalize(term)),
                "A transcrição sem contexto prévio não preservou um termo esperado do áudio de referência."
            )
        }
        for term in forbiddenTerms {
            XCTAssertFalse(
                normalizedTranscript.contains(normalize(term)),
                "A transcrição contém um termo que não foi falado no áudio adversarial."
            )
        }

        if let reference = environment["QAPIA_TRANSCRIPTION_REFERENCE_SEQUENCE"] {
            let transcriptWords = normalizedWords(transcript)
            let referenceWords = normalizedWords(reference)
            XCTAssertFalse(referenceWords.isEmpty)
            XCTAssertEqual(
                contiguousOccurrenceCount(of: referenceWords, in: transcriptWords),
                1,
                "O trecho-gabarito deve aparecer integralmente, na ordem correta e sem repetição."
            )
        }
    }

    func testSilenceFixtureDoesNotProduceInventedSpeechWhenProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["QAPIA_SILENCE_FIXTURE"] else {
            throw XCTSkip("Defina QAPIA_SILENCE_FIXTURE para validar um áudio sem fala.")
        }

        let segment = RecordingSegment(
            meetingID: UUID(),
            sequence: 1,
            fileURL: URL(fileURLWithPath: fixturePath),
            recordedDuration: 0
        )
        let transcript = try await WhisperCppService().transcribe(segment: segment)

        XCTAssertTrue(
            transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Ruído de fundo sem fala não pode virar uma transcrição inventada."
        )
    }

    func testWhisperProfilesAgainstRealAudioWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QAPIA_RUN_WHISPER_BENCHMARK"] == "1",
              let fixturePath = environment["QAPIA_TRANSCRIPTION_FIXTURE"] else {
            throw XCTSkip("Benchmark real executado apenas sob solicitação explícita.")
        }

        var samples = try await WhisperAudioDecoder.decodeMonoSamples(
            from: URL(fileURLWithPath: fixturePath)
        )
        if let seconds = environment["QAPIA_TRANSCRIPTION_BENCHMARK_SECONDS"]
            .flatMap(Double.init),
           seconds > 0 {
            samples = Array(samples.prefix(min(samples.count, Int(seconds * 16_000))))
        }
        let modelPath = environment["QAPIA_TRANSCRIPTION_MODEL"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Qapia/Whisper/ggml-small.bin")
                .path
        let profiles: [(String, WhisperDecodingProfile)] = [
            (
                "greedy-best-of-1",
                WhisperDecodingProfile(
                    languageCode: "pt",
                    keepsPreviousTextContext: false,
                    generatesSegmentTimestamps: true,
                    greedyBestOf: 1
                )
            ),
            (
                "greedy-best-of-2",
                WhisperDecodingProfile(
                    languageCode: "pt",
                    keepsPreviousTextContext: false,
                    generatesSegmentTimestamps: true,
                    greedyBestOf: 2
                )
            ),
            (
                "original-2026-08",
                WhisperDecodingProfile(
                    languageCode: "pt",
                    keepsPreviousTextContext: false,
                    generatesSegmentTimestamps: false,
                    greedyBestOf: 5
                )
            ),
            ("current", .highFidelityPortuguese),
            (
                "timestamp-history",
                WhisperDecodingProfile(
                    languageCode: "pt",
                    keepsPreviousTextContext: true,
                    generatesSegmentTimestamps: true,
                    greedyBestOf: 5
                )
            )
        ]

        let requestedProfiles = Set(
            environment["QAPIA_TRANSCRIPTION_BENCHMARK_PROFILES"]?
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
        )
        var benchmarkResults: [String: (elapsed: TimeInterval, transcript: String)] = [:]
        for (name, profile) in profiles where requestedProfiles.isEmpty || requestedProfiles.contains(name) {
            let startedAt = Date()
            let transcript = try WhisperEngine.transcribe(
                samples: samples,
                modelURL: URL(fileURLWithPath: modelPath),
                cancellationToken: WhisperCancellationToken(),
                profile: profile
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            benchmarkResults[name] = (elapsed, transcript)
            print("\n=== QAPIA BENCHMARK \(name) [\(elapsed)s, \(normalizedWords(transcript).count) palavras] ===\n\(transcript)\n=== END QAPIA BENCHMARK ===\n")
        }

        if let baseline = benchmarkResults["current"] {
            let baselineWords = normalizedWords(baseline.transcript)
            for name in ["greedy-best-of-1", "greedy-best-of-2"] {
                guard let candidate = benchmarkResults[name] else { continue }
                let candidateWords = normalizedWords(candidate.transcript)
                print(
                    "QAPIA BENCHMARK COMPARISON \(name): "
                        + "speedup=\(baseline.elapsed / candidate.elapsed), "
                        + "word_error_rate_vs_best_of_5="
                        + "\(wordErrorRate(reference: baselineWords, hypothesis: candidateWords))"
                )
            }
        }
    }

    private func normalize(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "pt_BR")
        )
    }

    private func normalizedWords(_ text: String) -> [String] {
        normalize(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private func contiguousOccurrenceCount(of needle: [String], in haystack: [String]) -> Int {
        guard !needle.isEmpty, needle.count <= haystack.count else { return 0 }
        return (0...(haystack.count - needle.count)).reduce(into: 0) { count, start in
            if Array(haystack[start..<(start + needle.count)]) == needle {
                count += 1
            }
        }
    }

    private func wordErrorRate(reference: [String], hypothesis: [String]) -> Double {
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        var previous = Array(0...hypothesis.count)
        for (referenceIndex, referenceWord) in reference.enumerated() {
            var current = [referenceIndex + 1] + Array(repeating: 0, count: hypothesis.count)
            for (hypothesisIndex, hypothesisWord) in hypothesis.enumerated() {
                current[hypothesisIndex + 1] = min(
                    current[hypothesisIndex] + 1,
                    previous[hypothesisIndex + 1] + 1,
                    previous[hypothesisIndex] + (referenceWord == hypothesisWord ? 0 : 1)
                )
            }
            previous = current
        }
        return Double(previous[hypothesis.count]) / Double(reference.count)
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
    }
}
