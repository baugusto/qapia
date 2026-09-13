@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
import whisper

public enum WhisperModelError: LocalizedError, Sendable, Equatable {
    case downloadFailed(String)
    case integrityCheckFailed
    case audioDecodingFailed(String)
    case transcriptionFailed

    public var errorDescription: String? {
        switch self {
        case let .downloadFailed(message):
            return "Não foi possível baixar o modelo local de transcrição: \(message)"
        case .integrityCheckFailed:
            return "O modelo baixado não passou na verificação de integridade."
        case let .audioDecodingFailed(message):
            return "Não foi possível ler o áudio para transcrição: \(message)"
        case .transcriptionFailed:
            return "A transcrição local não pôde ser concluída."
        }
    }
}

public struct WhisperModelDescriptor: Sendable, Equatable {
    public let fileName: String
    public let downloadURL: URL
    public let sha1: String

    public static let small = WhisperModelDescriptor(
        fileName: "ggml-small.bin",
        downloadURL: URL(
            string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
        )!,
        sha1: "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
    )

    static let legacyLargeV3Q5 = WhisperModelDescriptor(
        fileName: "ggml-large-v3-q5_0.bin",
        downloadURL: URL(
            string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"
        )!,
        sha1: "e6e2ed78495d403bef4b7cff42ef4aaadcfea8de"
    )
}

public actor WhisperModelStore {
    public static let shared = WhisperModelStore()

    private let descriptor: WhisperModelDescriptor
    private let destinationURL: URL
    private let bundledModelURL: URL?
    private var preparationTask: Task<URL, Error>?
    private var validatedModelURL: URL?

    public init(
        descriptor: WhisperModelDescriptor = .small,
        destinationURL: URL? = nil,
        bundledModelURL: URL? = nil
    ) {
        self.descriptor = descriptor
        self.destinationURL = destinationURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Qapia/Whisper/\(descriptor.fileName)")
        let resourceName = (descriptor.fileName as NSString).deletingPathExtension
        let resourceExtension = (descriptor.fileName as NSString).pathExtension
        self.bundledModelURL = bundledModelURL ?? Bundle.main.url(
            forResource: resourceName,
            withExtension: resourceExtension
        )
    }

    public func preparedModelURL() async throws -> URL {
        if let validatedModelURL,
           FileManager.default.fileExists(atPath: validatedModelURL.path) {
            return validatedModelURL
        }
        validatedModelURL = nil
        if let preparationTask {
            return try await preparationTask.value
        }

        let task = Task { try await prepareModel() }
        preparationTask = task
        do {
            let url = try await task.value
            preparationTask = nil
            validatedModelURL = url
            return url
        } catch {
            preparationTask = nil
            throw error
        }
    }

    private func prepareModel() async throws -> URL {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            if try sha1(of: destinationURL) == descriptor.sha1 {
                removeKnownLegacyModels(afterPreparing: destinationURL)
                return destinationURL
            }
        }

        // Prepare and validate the replacement before touching any existing
        // cache. This prevents a failed download from removing a usable model
        // during an upgrade.
        let preparedURL = try await bundledOrDownloadedModel()
        removeKnownLegacyModels(afterPreparing: preparedURL)
        return preparedURL
    }

    private func bundledOrDownloadedModel() async throws -> URL {
        if let bundledModelURL,
           FileManager.default.fileExists(atPath: bundledModelURL.path) {
            guard try sha1(of: bundledModelURL) == descriptor.sha1 else {
                throw WhisperModelError.integrityCheckFailed
            }
            // A fully standalone build loads the immutable, signed Small model
            // directly from its bundle instead of duplicating about 466 MB in
            // Application Support or requiring a first-launch download.
            return bundledModelURL
        }
        return try await downloadModel()
    }

    private func downloadModel() async throws -> URL {
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(
                from: descriptor.downloadURL
            )
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw WhisperModelError.downloadFailed("O servidor não confirmou o download.")
            }
            guard try sha1(of: temporaryURL) == descriptor.sha1 else {
                throw WhisperModelError.integrityCheckFailed
            }

            let directory = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try installValidatedDownload(temporaryURL)
            return destinationURL
        } catch let error as WhisperModelError {
            throw error
        } catch {
            throw WhisperModelError.downloadFailed(error.localizedDescription)
        }
    }

    private func installValidatedDownload(_ temporaryURL: URL) throws {
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            return
        }

        let staleURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(descriptor.fileName).stale-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: destinationURL, to: staleURL)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            try? FileManager.default.removeItem(at: staleURL)
        } catch {
            try? FileManager.default.moveItem(at: staleURL, to: destinationURL)
            throw error
        }
    }

    private func removeKnownLegacyModels(afterPreparing preparedURL: URL) {
        guard descriptor == .small,
              (try? sha1(of: preparedURL)) == descriptor.sha1 else { return }

        let directory = destinationURL.deletingLastPathComponent()
        let candidates = [
            directory.appendingPathComponent(WhisperModelDescriptor.legacyLargeV3Q5.fileName),
            destinationURL
        ]
        for candidate in candidates {
            guard candidate.standardizedFileURL != preparedURL.standardizedFileURL,
                  FileManager.default.fileExists(atPath: candidate.path),
                  (try? sha1(of: candidate)) == WhisperModelDescriptor.legacyLargeV3Q5.sha1 else {
                continue
            }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private func sha1(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct WhisperCppService: WhisperService {
    private let modelStore: WhisperModelStore
    private let inferenceSession: WhisperInferenceSession

    public init(modelStore: WhisperModelStore = .shared) {
        self.modelStore = modelStore
        inferenceSession = WhisperInferenceSession()
    }

    public func transcribe(segment: RecordingSegment) async throws -> String {
        try await transcribeWithDiagnostics(segment: segment).transcript
    }

    public func transcribeWithDiagnostics(
        segment: RecordingSegment
    ) async throws -> WhisperTranscriptionResult {
        let decodedAudio = try await WhisperAudioDecoder.decode(
            from: segment.fileURL,
            estimatedDuration: segment.recordedDuration
        )
        try Task.checkCancellation()
        // Whisper can confidently invent short phrases or labels such as
        // "[Música]" from the electrical noise floor. Reject only recordings
        // that are far below conservative speech-energy thresholds before the
        // model sees them; this keeps low voices while preventing fabricated
        // transcripts for effectively silent captures.
        if WhisperAudioContentAnalyzer.isEffectivelySilent(decodedAudio.samples) {
            return WhisperTranscriptionResult(
                transcript: "",
                warnings: decodedAudio.warnings
            )
        }

        let trimmedSamples = WhisperAudioTrimmer.trimmingTrailingSilence(
            from: decodedAudio.samples
        )
        let preparedSamples = WhisperAudioPreprocessor.prepare(trimmedSamples)

        let modelURL = try await modelStore.preparedModelURL()
        try Task.checkCancellation()
        let cancellationToken = WhisperCancellationToken()
        let inferenceSession = self.inferenceSession
        let task = Task.detached(priority: .background) {
            try inferenceSession.transcribe(
                samples: preparedSamples,
                modelURL: modelURL,
                cancellationToken: cancellationToken,
                profile: .highFidelityPortuguese
            )
        }
        return try await withTaskCancellationHandler {
            let transcript = try await task.value
            try Task.checkCancellation()
            let correctedTranscript = WhisperTranscriptPostprocessor.process(transcript)
            try Task.checkCancellation()
            return WhisperTranscriptionResult(
                transcript: correctedTranscript,
                warnings: decodedAudio.warnings
            )
        } onCancel: {
            cancellationToken.cancel()
            task.cancel()
        }
    }

    public func finishTranscriptionBatch() {
        inferenceSession.reset()
    }
}

struct WhisperAudioContentMetrics: Equatable, Sendable {
    let globalRMSDecibels: Double
    let windowRMS99thPercentileDecibels: Double
}

enum WhisperAudioContentAnalyzer {
    static let sampleRate = 16_000
    static let windowDuration = 0.020
    static let silentGlobalRMSDecibels = -65.0
    static let silentWindowRMS99thPercentileDecibels = -55.0

    static func isEffectivelySilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }

        // The gate only needs to compare both metrics with fixed thresholds.
        // Counting qualifying windows avoids allocating and sorting up to
        // hundreds of thousands of values for a long meeting. Once enough
        // speech-energy windows exist to cross p99, the result cannot be
        // silent and the scan can stop early.
        let windowSampleCount = max(1, Int(Double(sampleRate) * windowDuration))
        let windowCount = (samples.count + windowSampleCount - 1) / windowSampleCount
        let percentileIndex = min(
            windowCount - 1,
            max(0, Int(ceil(Double(windowCount) * 0.99)) - 1)
        )
        let qualifyingWindowCount = windowCount - percentileIndex
        let windowPowerThreshold = pow(
            10,
            silentWindowRMS99thPercentileDecibels / 10
        )
        let globalPowerThreshold = pow(10, silentGlobalRMSDecibels / 10)

        var totalPower = 0.0
        var activeWindowCount = 0
        var windowStart = 0
        while windowStart < samples.count {
            let windowEnd = min(windowStart + windowSampleCount, samples.count)
            var windowPower = 0.0
            for index in windowStart..<windowEnd {
                let finiteSample = samples[index].isFinite ? Double(samples[index]) : 0
                windowPower += finiteSample * finiteSample
            }
            totalPower += windowPower
            if windowPower / Double(windowEnd - windowStart) >= windowPowerThreshold {
                activeWindowCount += 1
                if activeWindowCount >= qualifyingWindowCount {
                    return false
                }
            }
            windowStart = windowEnd
        }

        return totalPower / Double(samples.count) < globalPowerThreshold
    }

    static func metrics(for samples: [Float]) -> WhisperAudioContentMetrics {
        guard !samples.isEmpty else {
            return WhisperAudioContentMetrics(
                globalRMSDecibels: -.infinity,
                windowRMS99thPercentileDecibels: -.infinity
            )
        }

        let windowSampleCount = max(1, Int(Double(sampleRate) * windowDuration))
        var totalPower = 0.0
        var windowPowers: [Double] = []
        windowPowers.reserveCapacity((samples.count + windowSampleCount - 1) / windowSampleCount)

        var windowPower = 0.0
        var samplesInWindow = 0
        for sample in samples {
            let finiteSample = sample.isFinite ? Double(sample) : 0
            let power = finiteSample * finiteSample
            totalPower += power
            windowPower += power
            samplesInWindow += 1

            if samplesInWindow == windowSampleCount {
                windowPowers.append(windowPower / Double(samplesInWindow))
                windowPower = 0
                samplesInWindow = 0
            }
        }
        if samplesInWindow > 0 {
            windowPowers.append(windowPower / Double(samplesInWindow))
        }

        windowPowers.sort()
        let percentileIndex = min(
            windowPowers.count - 1,
            max(0, Int(ceil(Double(windowPowers.count) * 0.99)) - 1)
        )
        return WhisperAudioContentMetrics(
            globalRMSDecibels: decibels(fromMeanSquare: totalPower / Double(samples.count)),
            windowRMS99thPercentileDecibels: decibels(
                fromMeanSquare: windowPowers[percentileIndex]
            )
        )
    }

    private static func decibels(fromMeanSquare meanSquare: Double) -> Double {
        guard meanSquare.isFinite, meanSquare > 0 else { return -.infinity }
        return 10 * log10(meanSquare)
    }
}

enum WhisperAudioPreprocessor {
    private static let sampleRate = 16_000.0
    private static let highPassFrequency = 70.0
    private static let targetRMSDecibels = -22.0
    private static let maximumGain: Float = 8
    private static let limiterKnee: Float = 0.84

    /// Conditions low-level meeting audio before inference without changing its
    /// duration. The high-pass removes handling/desk rumble and the bounded
    /// loudness gain brings a quiet microphone closer to the range on which
    /// Whisper is most reliable. A soft limiter protects occasional peaks.
    static func prepare(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let timeStep = 1 / sampleRate
        let resistanceCapacitance = 1 / (2 * Double.pi * highPassFrequency)
        let alpha = Float(resistanceCapacitance / (resistanceCapacitance + timeStep))
        var filtered = [Float](repeating: 0, count: samples.count)
        var previousInput: Float = samples[0].isFinite ? samples[0] : 0
        var previousOutput: Float = 0
        var power = 0.0

        for index in samples.indices {
            let input = samples[index].isFinite ? samples[index] : 0
            let output = alpha * (previousOutput + input - previousInput)
            filtered[index] = output
            power += Double(output * output)
            previousInput = input
            previousOutput = output
        }

        let rms = sqrt(power / Double(filtered.count))
        guard rms.isFinite, rms > 0 else { return filtered }
        let targetRMS = pow(10, targetRMSDecibels / 20)
        let gain = Float(min(Double(maximumGain), max(1, targetRMS / rms)))
        guard gain > 1.001 else { return filtered }

        // Mutate the filtered buffer in place. For one hour at 16 kHz this
        // avoids a second temporary allocation of roughly 230 MB.
        for index in filtered.indices {
            let amplified = filtered[index] * gain
            let magnitude = abs(amplified)
            guard magnitude > limiterKnee else {
                filtered[index] = amplified
                continue
            }
            let remainingHeadroom = 1 - limiterKnee
            let compressed = limiterKnee + remainingHeadroom * (
                1 - exp(-(magnitude - limiterKnee) / remainingHeadroom)
            )
            filtered[index] = amplified.sign == .minus ? -compressed : compressed
        }
        return filtered
    }
}

enum WhisperAudioTrimmer {
    private static let sampleRate = 16_000
    private static let windowSampleCount = 320
    private static let activeRMSDecibels = -60.0
    private static let minimumTrailingSilenceSamples = Int(0.8 * Double(sampleRate))
    private static let preservedTailSamples = Int(0.25 * Double(sampleRate))

    /// Trailing silence can make Whisper append stock phrases after genuine
    /// speech. Keep a short safety tail and trim only a sustained, very quiet
    /// ending; short pauses and quiet voices remain untouched.
    static func trimmingTrailingSilence(from samples: [Float]) -> [Float] {
        guard samples.count > minimumTrailingSilenceSamples else { return samples }

        // Only the final active window matters. Scan the same 20 ms-aligned
        // windows backwards so a normal hour-long recording with speech near
        // its end does not require another full pass over every sample.
        var windowStart = ((samples.count - 1) / windowSampleCount) * windowSampleCount
        while true {
            let windowEnd = min(windowStart + windowSampleCount, samples.count)
            var power = 0.0
            for index in windowStart..<windowEnd {
                let sample = samples[index].isFinite ? Double(samples[index]) : 0
                power += sample * sample
            }
            let rms = sqrt(power / Double(windowEnd - windowStart))
            let decibels = rms > 0 ? 20 * log10(rms) : -Double.infinity
            if decibels >= activeRMSDecibels {
                let proposedEnd = min(samples.count, windowEnd + preservedTailSamples)
                guard samples.count - proposedEnd >= minimumTrailingSilenceSamples else {
                    return samples
                }
                return Array(samples[..<proposedEnd])
            }
            guard windowStart > 0 else { return samples }
            windowStart = max(0, windowStart - windowSampleCount)
        }
    }
}

enum WhisperTranscriptSanitizer {
    private static let nonSpeechLabels: Set<String> = [
        "[musica]",
        "[music]",
        "[silencio]",
        "[silence]",
        "[som de botao]"
    ]

    static func removingNonSpeechOnlyResult(_ transcript: String) -> String {
        transcript
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { line in
                let normalized = line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: Locale(identifier: "pt_BR")
                    )
                return !normalized.isEmpty && !nonSpeechLabels.contains(normalized)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WhisperTranscriptPostprocessor {
    private struct Token {
        let range: NSRange
        let normalized: String
    }

    private static let tokenExpression = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}]+"
    )
    private static let minimumDuplicateTokenCount = 12

    static func process(_ transcript: String) -> String {
        let withoutLongEcho = removeRepeatedPassages(from: transcript)
        let withoutTrailingEcho = removeTrailingOpeningEcho(from: withoutLongEcho)
        return collapseRepeatedTail(from: withoutTrailingEcho)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper Small can append a near-verbatim fragment from its opening
    /// window after the real ending. Remove the final sentence only when all
    /// but at most four leading tokens match a long sequence near the start.
    static func removeTrailingOpeningEcho(from transcript: String) -> String {
        let transcriptTokens = tokens(in: transcript)
        guard transcriptTokens.count >= minimumDuplicateTokenCount * 2,
              let finalToken = transcriptTokens.last else { return transcript }

        let source = transcript as NSString
        var sentenceStartLocation = finalToken.range.location
        while sentenceStartLocation > 0 {
            let previous = source.character(at: sentenceStartLocation - 1)
            if previous == 10 || previous == 13 || isSentenceTerminator(previous) {
                break
            }
            sentenceStartLocation -= 1
        }
        guard let finalSentenceStart = transcriptTokens.firstIndex(where: {
            $0.range.location >= sentenceStartLocation
        }) else { return transcript }
        let finalSentenceTokens = Array(transcriptTokens[finalSentenceStart...])
        guard finalSentenceTokens.count >= minimumDuplicateTokenCount else { return transcript }

        let maximumLeadingDifference = min(
            4,
            finalSentenceTokens.count - minimumDuplicateTokenCount
        )
        for droppedLeadingTokens in 0...maximumLeadingDifference {
            let pattern = Array(finalSentenceTokens.dropFirst(droppedLeadingTokens))
                .map(\.normalized)
            let latestOpeningStart = finalSentenceStart - pattern.count - 4
            guard latestOpeningStart >= 0 else { continue }
            for openingStart in 0...min(40, latestOpeningStart) {
                let opening = transcriptTokens[openingStart..<(openingStart + pattern.count)]
                    .map(\.normalized)
                guard opening == pattern else { continue }
                return source.substring(to: sentenceStartLocation)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return transcript
    }

    /// Removes only a clear decoder loop: three or more identical phrases of
    /// at least five tokens repeated consecutively at the very end. Repeated
    /// speech elsewhere, and a phrase repeated only twice, remain untouched.
    static func collapseRepeatedTail(from transcript: String) -> String {
        let transcriptTokens = tokens(in: transcript)
        guard transcriptTokens.count >= 15 else { return transcript }

        let largestPhrase = min(16, transcriptTokens.count / 3)
        for phraseLength in stride(from: largestPhrase, through: 5, by: -1) {
            let phraseStart = transcriptTokens.count - phraseLength
            let phrase = transcriptTokens[phraseStart...].map(\.normalized)
            var firstCopyStart = phraseStart
            var repeatCount = 1
            while firstCopyStart >= phraseLength {
                let candidateStart = firstCopyStart - phraseLength
                let candidate = transcriptTokens[candidateStart..<firstCopyStart]
                    .map(\.normalized)
                guard candidate == phrase else { break }
                repeatCount += 1
                firstCopyStart = candidateStart
            }
            guard repeatCount >= 3 else { continue }

            let keptCopyLastToken = transcriptTokens[firstCopyStart + phraseLength - 1]
            let finalToken = transcriptTokens.last!
            let source = transcript as NSString
            let prefix = source.substring(to: NSMaxRange(keptCopyLastToken.range))
            let suffix = source.substring(from: NSMaxRange(finalToken.range))
            return (prefix + suffix)
                .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        }
        return transcript
    }

    static func removeRepeatedPassages(from transcript: String) -> String {
        var result = transcript
        for _ in 0..<4 {
            guard !Task<Never, Never>.isCancelled else { break }
            let transcriptTokens = tokens(in: result)
            guard transcriptTokens.count >= minimumDuplicateTokenCount * 2 else { break }

            // Restrict deletion to a long echo of the opening passage after
            // intervening content. Whisper occasionally loops back to its
            // opening window after a long decode. Repeated speech
            // elsewhere (or an immediate deliberate repetition) is preserved.
            var bestDuplicate: (start: Int, length: Int)?
            let finalStart = transcriptTokens.count - minimumDuplicateTokenCount
            let openingKey = transcriptTokens.prefix(minimumDuplicateTokenCount)
                .map(\.normalized)
            let earliestEchoStart = minimumDuplicateTokenCount
            guard earliestEchoStart <= finalStart else { break }
            for start in earliestEchoStart...finalStart {
                let candidateKey = transcriptTokens[start..<(start + minimumDuplicateTokenCount)]
                    .map(\.normalized)
                guard candidateKey == openingKey else { continue }
                var length = minimumDuplicateTokenCount
                while start + length < transcriptTokens.count,
                      length < start,
                      transcriptTokens[length].normalized
                        == transcriptTokens[start + length].normalized {
                    length += 1
                }
                // A directly repeated sentence can be intentional. Treat it as
                // an ASR echo only when other content separates both copies.
                guard start >= length + 4 else { continue }
                if bestDuplicate == nil || length > bestDuplicate!.length {
                    bestDuplicate = (start, length)
                }
            }

            guard let duplicate = bestDuplicate else { break }
            let firstRange = transcriptTokens[duplicate.start].range
            let lastRange = transcriptTokens[duplicate.start + duplicate.length - 1].range
            var removalRange = NSRange(
                location: firstRange.location,
                length: NSMaxRange(lastRange) - firstRange.location
            )
            let source = result as NSString
            while removalRange.location > 0,
                  isWhitespace(source.character(at: removalRange.location - 1)) {
                removalRange.location -= 1
                removalRange.length += 1
            }
            while NSMaxRange(removalRange) < source.length,
                  isTrailingSeparator(source.character(at: NSMaxRange(removalRange))) {
                removalRange.length += 1
            }
            let replacement: String
            if removalRange.location == 0 {
                replacement = ""
            } else {
                let previous = source.character(at: removalRange.location - 1)
                replacement = isSentenceTerminator(previous) ? " " : ". "
            }
            result = source.replacingCharacters(in: removalRange, with: replacement)
        }
        return result
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
    }

    private static func tokens(in text: String) -> [Token] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return tokenExpression.matches(in: text, range: range).map { match in
            let raw = (text as NSString).substring(with: match.range)
            return Token(range: match.range, normalized: normalizedCharacters(raw))
        }
    }

    private static func normalizedCharacters(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "pt_BR")
        ).unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func isWhitespace(_ utf16CodeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(utf16CodeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isTrailingSeparator(_ utf16CodeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(utf16CodeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.punctuationCharacters.contains(scalar)
    }

    private static func isSentenceTerminator(_ utf16CodeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(utf16CodeUnit) else { return false }
        return scalar == "." || scalar == "!" || scalar == "?"
    }
}

enum WhisperAudioDecoder {
    private static let targetSampleRate = 16_000.0
    private static let minimumRecoverableDuration = 0.5
    private static let partialAudioWarning =
        "Uma das fontes de áudio terminou de forma incompleta; "
        + "a transcrição preservou todo o trecho que pôde ser lido com segurança."

    struct DecodedAudio: Sendable, Equatable {
        let samples: [Float]
        let warnings: [String]
    }

    private struct DecodeCandidate {
        let samples: [Float]
        let isPartial: Bool
    }

    static func decodeMonoSamples(from fileURL: URL) async throws -> [Float] {
        try await decode(from: fileURL).samples
    }

    static func decode(
        from fileURL: URL,
        estimatedDuration: TimeInterval? = nil
    ) async throws -> DecodedAudio {
        do {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: fileURL)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                throw WhisperModelError.audioDecodingFailed("O arquivo não contém faixas de áudio.")
            }

            var mixedPartialCandidate: DecodeCandidate?
            var primaryDiagnostic = ""
            do {
                let mixedCandidate = try decodeMixedTracks(
                    audioTracks,
                    in: asset,
                    estimatedDuration: estimatedDuration
                )
                if !mixedCandidate.isPartial {
                    return DecodedAudio(samples: mixedCandidate.samples, warnings: [])
                }
                mixedPartialCandidate = mixedCandidate
                primaryDiagnostic = "a leitura combinada terminou antes do fim"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                primaryDiagnostic = diagnosticMessage(for: error)
            }

            // Preserve every readable track if one malformed track prevents the
            // optimized AVAudioMix path from opening or finishing the whole asset.
            // A complete per-track decode always wins over a longer partial mix.
            var decodedTracks: [DecodeCandidate] = []
            var trackErrors: [String] = []
            for (index, track) in audioTracks.enumerated() {
                try Task.checkCancellation()
                var convertedCandidate: DecodeCandidate?
                var convertedDiagnostic = ""
                do {
                    let candidate = try decodeTrack(
                        track,
                        in: asset,
                        estimatedDuration: estimatedDuration
                    )
                    if !candidate.isPartial {
                        decodedTracks.append(candidate)
                        continue
                    }
                    convertedCandidate = candidate
                    convertedDiagnostic = "conversão incompleta"
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    convertedDiagnostic = diagnosticMessage(for: error)
                }

                do {
                    let rawCandidate = try decodeRawPCMTrack(
                        track,
                        in: asset,
                        estimatedDuration: estimatedDuration
                    )
                    if !rawCandidate.isPartial
                        || rawCandidate.samples.count >= (convertedCandidate?.samples.count ?? 0) {
                        decodedTracks.append(rawCandidate)
                    } else if let convertedCandidate {
                        decodedTracks.append(convertedCandidate)
                    }
                    if rawCandidate.isPartial {
                        trackErrors.append("faixa \(index + 1): leitura PCM incompleta")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if let convertedCandidate {
                        decodedTracks.append(convertedCandidate)
                        trackErrors.append("faixa \(index + 1): \(convertedDiagnostic)")
                    } else {
                        trackErrors.append(
                            "faixa \(index + 1): conversão \(convertedDiagnostic); "
                                + "PCM nativo \(diagnosticMessage(for: error))"
                        )
                    }
                }
            }

            if !decodedTracks.isEmpty {
                let perTrackCandidate = DecodeCandidate(
                    samples: mix(decodedTracks.map(\.samples)),
                    isPartial: decodedTracks.contains(where: \.isPartial)
                        || decodedTracks.count < audioTracks.count
                )
                let selectedCandidate: DecodeCandidate
                if !perTrackCandidate.isPartial {
                    selectedCandidate = perTrackCandidate
                } else if let mixedPartialCandidate,
                          mixedPartialCandidate.samples.count > perTrackCandidate.samples.count {
                    selectedCandidate = mixedPartialCandidate
                } else {
                    selectedCandidate = perTrackCandidate
                }
                let warnings = selectedCandidate.isPartial || !trackErrors.isEmpty
                    ? [partialAudioWarning]
                    : []
                return DecodedAudio(samples: selectedCandidate.samples, warnings: warnings)
            }

            // Recovered recordings can still be raw PCM CAF files. AVAudioFile
            // provides an independent path for those files if AVAssetReader fails.
            do {
                let pcmCandidate = try decodePCMFile(
                    at: fileURL,
                    estimatedDuration: estimatedDuration
                )
                let selectedCandidate: DecodeCandidate
                if !pcmCandidate.isPartial {
                    selectedCandidate = pcmCandidate
                } else if let mixedPartialCandidate,
                          mixedPartialCandidate.samples.count > pcmCandidate.samples.count {
                    selectedCandidate = mixedPartialCandidate
                } else {
                    selectedCandidate = pcmCandidate
                }
                return DecodedAudio(
                    samples: selectedCandidate.samples,
                    warnings: selectedCandidate.isPartial ? [partialAudioWarning] : []
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let mixedPartialCandidate {
                    return DecodedAudio(
                        samples: mixedPartialCandidate.samples,
                        warnings: [partialAudioWarning]
                    )
                }
                let details = ([
                    "mix: \(primaryDiagnostic)",
                    trackErrors.joined(separator: "; "),
                    "PCM: \(diagnosticMessage(for: error))"
                ]).filter { !$0.isEmpty }.joined(separator: "; ")
                throw WhisperModelError.audioDecodingFailed(details)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WhisperModelError {
            throw error
        } catch {
            throw WhisperModelError.audioDecodingFailed(diagnosticMessage(for: error))
        }
    }

    private static func decodeMixedTracks(
        _ audioTracks: [AVAssetTrack],
        in asset: AVAsset,
        estimatedDuration: TimeInterval?
    ) throws -> DecodeCandidate {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: canonicalOutputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw WhisperModelError.audioDecodingFailed("Não foi possível combinar as faixas de áudio.")
        }
        reader.add(output)
        return try readSamples(
            from: output,
            using: reader,
            estimatedSampleCount: estimatedSampleCount(
                duration: estimatedDuration,
                sampleRate: targetSampleRate
            )
        )
    }

    private static func decodeTrack(
        _ track: AVAssetTrack,
        in asset: AVAsset,
        estimatedDuration: TimeInterval?
    ) throws -> DecodeCandidate {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: canonicalOutputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw WhisperModelError.audioDecodingFailed("Não foi possível abrir a faixa de áudio.")
        }
        reader.add(output)
        return try readSamples(
            from: output,
            using: reader,
            estimatedSampleCount: estimatedSampleCount(
                duration: estimatedDuration,
                sampleRate: targetSampleRate
            )
        )
    }

    private static func decodeRawPCMTrack(
        _ track: AVAssetTrack,
        in asset: AVAsset,
        estimatedDuration: TimeInterval?
    ) throws -> DecodeCandidate {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw WhisperModelError.audioDecodingFailed("Não foi possível abrir a faixa PCM nativa.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw WhisperModelError.audioDecodingFailed(
                diagnosticMessage(
                    for: reader.error,
                    fallback: "Não foi possível iniciar a leitura PCM nativa."
                )
            )
        }

        var sourceSampleRate: Double?
        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let sampleFrameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard sampleFrameCount > 0 else { continue }
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                throw WhisperModelError.audioDecodingFailed(
                    "A amostra PCM de \(sampleFrameCount) quadros não informou uma descrição de formato."
                )
            }
            guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
                throw WhisperModelError.audioDecodingFailed(
                    "A descrição da faixa não informou seu formato PCM."
                )
            }
            let format = streamDescription.pointee
            guard format.mFormatID == kAudioFormatLinearPCM else {
                throw WhisperModelError.audioDecodingFailed(
                    "A faixa nativa usa um codec comprimido que requer o decodificador do macOS."
                )
            }
            guard sourceSampleRate == nil || abs(sourceSampleRate! - format.mSampleRate) < 0.01 else {
                throw WhisperModelError.audioDecodingFailed(
                    "A taxa de amostragem mudou durante a faixa PCM."
                )
            }
            sourceSampleRate = format.mSampleRate
            if samples.isEmpty,
               let capacity = estimatedSampleCount(
                   duration: estimatedDuration,
                   sampleRate: format.mSampleRate
               ) {
                samples.reserveCapacity(capacity)
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw WhisperModelError.audioDecodingFailed(
                    "A faixa PCM nativa não forneceu dados contíguos."
                )
            }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: byteCount)
            let copyStatus = bytes.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: destination.baseAddress!
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw WhisperModelError.audioDecodingFailed(
                    "Não foi possível copiar a faixa PCM nativa (\(copyStatus))."
                )
            }
            samples.append(contentsOf: try decodePCMBytes(
                bytes,
                frameCount: sampleFrameCount,
                format: format
            ))
        }

        if reader.status == .cancelled || Task.isCancelled {
            throw CancellationError()
        }
        guard let sourceSampleRate, !samples.isEmpty else {
            throw WhisperModelError.audioDecodingFailed("A faixa PCM nativa está vazia.")
        }
        let isPartial = reader.status == .failed
        if isPartial {
            try requireMinimumRecoverableDuration(
                sampleCount: samples.count,
                sampleRate: sourceSampleRate,
                underlyingError: reader.error,
                fallback: "A leitura PCM nativa foi interrompida."
            )
        }
        return DecodeCandidate(
            samples: resample(samples, from: sourceSampleRate, to: targetSampleRate),
            isPartial: isPartial
        )
    }

    private static var canonicalOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static func readSamples(
        from output: AVAssetReaderOutput,
        using reader: AVAssetReader,
        estimatedSampleCount: Int?
    ) throws -> DecodeCandidate {
        guard reader.startReading() else {
            throw WhisperModelError.audioDecodingFailed(
                diagnosticMessage(
                    for: reader.error,
                    fallback: "Não foi possível iniciar a leitura do áudio."
                )
            )
        }

        var samples: [Float] = []
        if let estimatedSampleCount {
            samples.reserveCapacity(estimatedSampleCount)
        }
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw WhisperModelError.audioDecodingFailed(
                    "A faixa decodificada não forneceu um bloco PCM contíguo."
                )
            }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount > 0 else { continue }
            guard byteCount.isMultiple(of: MemoryLayout<Float>.size) else {
                throw WhisperModelError.audioDecodingFailed(
                    "A faixa retornou um bloco PCM com tamanho inválido."
                )
            }

            var bufferSamples = [Float](
                repeating: 0,
                count: byteCount / MemoryLayout<Float>.size
            )
            let copyStatus = bufferSamples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: bytes.baseAddress!
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw WhisperModelError.audioDecodingFailed(
                    "Não foi possível copiar as amostras de áudio (\(copyStatus))."
                )
            }
            for index in bufferSamples.indices where !bufferSamples[index].isFinite {
                bufferSamples[index] = 0
            }
            samples.append(contentsOf: bufferSamples)
        }

        if reader.status == .cancelled || Task.isCancelled {
            throw CancellationError()
        }
        guard !samples.isEmpty else {
            throw WhisperModelError.audioDecodingFailed("O segmento não contém amostras de áudio.")
        }
        let isPartial = reader.status == .failed
        if isPartial {
            try requireMinimumRecoverableDuration(
                sampleCount: samples.count,
                sampleRate: targetSampleRate,
                underlyingError: reader.error,
                fallback: "A leitura do áudio foi interrompida."
            )
        }
        return DecodeCandidate(samples: samples, isPartial: isPartial)
    }

    private static func decodePCMBytes(
        _ bytes: [UInt8],
        frameCount: Int,
        format: AudioStreamBasicDescription
    ) throws -> [Float] {
        let channelCount = Int(format.mChannelsPerFrame)
        let bytesPerSample = Int(format.mBitsPerChannel / 8)
        let bytesPerFrame = Int(format.mBytesPerFrame)
        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard channelCount > 0,
              frameCount > 0,
              bytesPerSample > 0,
              bytesPerFrame > 0,
              format.mBitsPerChannel.isMultiple(of: 8)
        else {
            throw WhisperModelError.audioDecodingFailed("O formato PCM nativo é inválido.")
        }

        let requiredByteCount = isNonInterleaved
            ? channelCount * frameCount * bytesPerFrame
            : frameCount * bytesPerFrame
        guard bytes.count >= requiredByteCount else {
            throw WhisperModelError.audioDecodingFailed(
                "A faixa PCM terminou antes do número de quadros informado."
            )
        }

        var output = [Float](repeating: 0, count: frameCount)
        try bytes.withUnsafeBytes { rawBytes in
            for frame in 0..<frameCount {
                var mixed: Float = 0
                for channel in 0..<channelCount {
                    let offset: Int
                    if isNonInterleaved {
                        offset = channel * frameCount * bytesPerFrame + frame * bytesPerFrame
                    } else {
                        offset = frame * bytesPerFrame + channel * bytesPerSample
                    }
                    mixed += try decodePCMSample(
                        from: rawBytes,
                        at: offset,
                        format: format
                    )
                }
                let sample = mixed / Float(channelCount)
                output[frame] = sample.isFinite ? sample : 0
            }
        }
        return output
    }

    private static func decodePCMSample(
        from bytes: UnsafeRawBufferPointer,
        at offset: Int,
        format: AudioStreamBasicDescription
    ) throws -> Float {
        let isBigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0

        if isFloat, format.mBitsPerChannel == 32 {
            let raw = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            let native = isBigEndian ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw)
            return Float(bitPattern: native)
        }
        if isFloat, format.mBitsPerChannel == 64 {
            let raw = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            let native = isBigEndian ? UInt64(bigEndian: raw) : UInt64(littleEndian: raw)
            return Float(Double(bitPattern: native))
        }
        if isSignedInteger, format.mBitsPerChannel == 16 {
            let raw = bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            let native = isBigEndian ? UInt16(bigEndian: raw) : UInt16(littleEndian: raw)
            return Float(Int16(bitPattern: native)) / 32_768
        }
        if isSignedInteger, format.mBitsPerChannel == 24 {
            let first = UInt32(bytes[offset])
            let second = UInt32(bytes[offset + 1])
            let third = UInt32(bytes[offset + 2])
            var value = isBigEndian
                ? (first << 16) | (second << 8) | third
                : first | (second << 8) | (third << 16)
            if value & 0x80_0000 != 0 {
                value |= 0xFF00_0000
            }
            return Float(Int32(bitPattern: value)) / 8_388_608
        }
        if isSignedInteger, format.mBitsPerChannel == 32 {
            let raw = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            let native = isBigEndian ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw)
            return Float(Int32(bitPattern: native)) / 2_147_483_648
        }
        if format.mBitsPerChannel == 8 {
            if isSignedInteger {
                return Float(Int8(bitPattern: bytes[offset])) / 128
            }
            return (Float(bytes[offset]) - 128) / 128
        }

        throw WhisperModelError.audioDecodingFailed(
            "PCM de \(format.mBitsPerChannel) bits não é compatível com a transcrição."
        )
    }

    private static func decodePCMFile(
        at fileURL: URL,
        estimatedDuration: TimeInterval?
    ) throws -> DecodeCandidate {
        let file = try AVAudioFile(
            forReading: fileURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0, format.sampleRate > 0 else {
            throw WhisperModelError.audioDecodingFailed("O arquivo PCM não possui formato de áudio válido.")
        }

        let frameCapacity: AVAudioFrameCount = 16_384
        var monoSamples: [Float] = []
        if let capacity = estimatedSampleCount(
            duration: estimatedDuration,
            sampleRate: format.sampleRate
        ) {
            monoSamples.reserveCapacity(capacity)
        }
        var endedWithReadFailure = false
        while true {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            ) else {
                throw WhisperModelError.audioDecodingFailed("Não foi possível alocar o buffer PCM.")
            }
            do {
                try file.read(into: buffer, frameCount: frameCapacity)
            } catch {
                try requireMinimumRecoverableDuration(
                    sampleCount: monoSamples.count,
                    sampleRate: format.sampleRate,
                    underlyingError: error,
                    fallback: "A leitura do arquivo PCM foi interrompida."
                )
                endedWithReadFailure = true
                break
            }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw WhisperModelError.audioDecodingFailed("O arquivo PCM não forneceu amostras Float32.")
            }

            for frame in 0..<frameCount {
                var mixed: Float = 0
                for channel in 0..<channelCount {
                    let sample = channels[channel][frame]
                    mixed += sample.isFinite ? sample : 0
                }
                monoSamples.append(mixed / Float(channelCount))
            }
        }

        guard !monoSamples.isEmpty else {
            throw WhisperModelError.audioDecodingFailed("O segmento PCM não contém amostras de áudio.")
        }
        return DecodeCandidate(
            samples: resample(
                monoSamples,
                from: format.sampleRate,
                to: targetSampleRate
            ),
            isPartial: endedWithReadFailure
        )
    }

    private static func requireMinimumRecoverableDuration(
        sampleCount: Int,
        sampleRate: Double,
        underlyingError: Error?,
        fallback: String
    ) throws {
        let duration = sampleRate > 0 ? Double(sampleCount) / sampleRate : 0
        guard duration >= minimumRecoverableDuration else {
            throw WhisperModelError.audioDecodingFailed(
                diagnosticMessage(for: underlyingError, fallback: fallback)
            )
        }
    }

    private static func estimatedSampleCount(
        duration: TimeInterval?,
        sampleRate: Double
    ) -> Int? {
        guard let duration,
              duration.isFinite,
              duration > 0,
              sampleRate.isFinite,
              sampleRate > 0 else { return nil }
        // Recording metadata is only a capacity hint. Cap it so corrupt
        // metadata cannot trigger an excessive eager allocation.
        let maximumReservationDuration: TimeInterval = 2 * 60 * 60
        return Int(min(duration, maximumReservationDuration) * sampleRate)
    }

    private static func resample(
        _ samples: [Float],
        from sourceRate: Double,
        to destinationRate: Double
    ) -> [Float] {
        guard abs(sourceRate - destinationRate) > 0.01 else { return samples }
        let outputCount = max(
            1,
            Int((Double(samples.count) * destinationRate / sourceRate).rounded())
        )
        var output = [Float](repeating: 0, count: outputCount)
        let sourceFramesPerOutputFrame = sourceRate / destinationRate
        for outputIndex in output.indices {
            let sourcePosition = Double(outputIndex) * sourceFramesPerOutputFrame
            let lowerIndex = min(Int(sourcePosition), samples.count - 1)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            output[outputIndex] = samples[lowerIndex]
                + (samples[upperIndex] - samples[lowerIndex]) * fraction
        }
        return output
    }

    private static func mix(_ tracks: [[Float]]) -> [Float] {
        guard tracks.count > 1 else { return tracks[0] }
        let sampleCount = tracks.map(\.count).max() ?? 0
        var mixed = [Float](repeating: 0, count: sampleCount)
        let scale = 1 / Float(tracks.count)
        for track in tracks {
            for index in track.indices {
                mixed[index] += track[index] * scale
            }
        }
        return mixed
    }

    private static func diagnosticMessage(
        for error: Error?,
        fallback: String = "Falha desconhecida ao decodificar o áudio."
    ) -> String {
        guard let error else { return fallback }
        let nsError = error as NSError
        var components = ["\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            components.append(
                "causa \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
            )
        }
        return components.joined(separator: ", ")
    }
}

final class WhisperCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    static func isCancellationRequested(_ userData: UnsafeMutableRawPointer?) -> Bool {
        guard let userData else { return false }
        return Unmanaged<WhisperCancellationToken>
            .fromOpaque(userData)
            .takeUnretainedValue()
            .isCancelled
    }
}

struct WhisperDecodingProfile: Equatable, Sendable {
    let languageCode: String
    let keepsPreviousTextContext: Bool
    let generatesSegmentTimestamps: Bool
    let greedyBestOf: Int32

    /// Accuracy-first defaults for meeting audio in Brazilian Portuguese.
    ///
    /// Whisper needs its timestamp tokens to advance through speech reliably,
    /// even though QAP.ia does not display timestamps in the transcript. Past
    /// text context remains disabled because the real-audio comparison did not
    /// improve recognition and carrying it across long decode windows can
    /// reinforce repetitions or hallucinated phrases.
    static let highFidelityPortuguese = WhisperDecodingProfile(
        languageCode: "pt",
        keepsPreviousTextContext: false,
        generatesSegmentTimestamps: true,
        greedyBestOf: 5
    )
}

enum WhisperPerformanceConfiguration {
    static let maximumInferenceThreadCount = 8

    static var inferenceThreadCount: Int32 {
        recommendedThreadCount(
            performanceCoreCount: systemInteger(named: "hw.perflevel0.logicalcpu"),
            physicalCoreCount: systemInteger(named: "hw.physicalcpu"),
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
        )
    }

    /// Prefer macOS performance cores and avoid unbounded thread counts. The
    /// Whisper decoder is memory-bandwidth sensitive, so using efficiency
    /// cores or every core on large Apple Silicon chips can add contention
    /// without reducing latency.
    static func recommendedThreadCount(
        performanceCoreCount: Int?,
        physicalCoreCount: Int?,
        activeProcessorCount: Int
    ) -> Int32 {
        let availableProcessorCount = max(1, activeProcessorCount)
        let preferredCount = [performanceCoreCount, physicalCoreCount]
            .compactMap { $0 }
            .first { $0 > 0 }
            ?? availableProcessorCount
        return Int32(min(maximumInferenceThreadCount, availableProcessorCount, preferredCount))
    }

    private static func systemInteger(named name: String) -> Int? {
        var value: Int32 = 0
        var valueSize = MemoryLayout<Int32>.size
        let status = name.withCString { namePointer in
            sysctlbyname(namePointer, &value, &valueSize, nil, 0)
        }
        guard status == 0, value > 0 else { return nil }
        return Int(value)
    }
}

/// Owns one whisper.cpp context for the pause/resume segments of a meeting.
/// `whisper_full` is not thread-safe for a shared context, so the lock also
/// serializes accidental concurrent calls without duplicating the ~466 MB
/// Small model in memory. `TranscriptionService` resets the session before the
/// summary stage to return that memory to the system.
final class WhisperInferenceSession: @unchecked Sendable {
    private let lock = NSLock()
    private var context: OpaquePointer?
    private var modelURL: URL?

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    func transcribe(
        samples: [Float],
        modelURL: URL,
        cancellationToken: WhisperCancellationToken,
        profile: WhisperDecodingProfile
    ) throws -> String {
        guard !cancellationToken.isCancelled else { throw CancellationError() }
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationToken.isCancelled else { throw CancellationError() }

        let standardizedModelURL = modelURL.standardizedFileURL
        if self.modelURL != standardizedModelURL {
            releaseContext()
        }
        if context == nil {
            context = try WhisperEngine.makeContext(modelURL: standardizedModelURL)
            self.modelURL = standardizedModelURL
        }
        guard let context else { throw WhisperModelError.transcriptionFailed }
        do {
            return try WhisperEngine.transcribeUsingContext(
                samples: samples,
                context: context,
                cancellationToken: cancellationToken,
                profile: profile
            )
        } catch {
            // Do not reuse decoder state after a failed or aborted native call.
            releaseContext()
            throw error
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        releaseContext()
    }

    private func releaseContext() {
        if let context {
            whisper_free(context)
        }
        context = nil
        modelURL = nil
    }
}

enum WhisperEngine {
    static func transcribe(
        samples: [Float],
        modelURL: URL,
        cancellationToken: WhisperCancellationToken,
        profile: WhisperDecodingProfile = .highFidelityPortuguese
    ) throws -> String {
        guard !cancellationToken.isCancelled else { throw CancellationError() }
        let context = try makeContext(modelURL: modelURL)
        defer { whisper_free(context) }
        guard !cancellationToken.isCancelled else { throw CancellationError() }
        return try transcribeUsingContext(
            samples: samples,
            context: context,
            cancellationToken: cancellationToken,
            profile: profile
        )
    }

    static func makeContext(modelURL: URL) throws -> OpaquePointer {
        let contextParameters = contextParameters()
        let context = modelURL.path.withCString {
            whisper_init_from_file_with_params($0, contextParameters)
        }
        guard let context else { throw WhisperModelError.transcriptionFailed }
        return context
    }

    static func transcribeUsingContext(
        samples: [Float],
        context: OpaquePointer,
        cancellationToken: WhisperCancellationToken,
        profile: WhisperDecodingProfile
    ) throws -> String {
        guard !cancellationToken.isCancelled else { throw CancellationError() }
        let tokenPointer = Unmanaged.passRetained(cancellationToken).toOpaque()
        defer {
            Unmanaged<WhisperCancellationToken>.fromOpaque(tokenPointer).release()
        }

        var parameters = parameters(for: profile)
        parameters.abort_callback = { userData in
            WhisperCancellationToken.isCancellationRequested(userData)
        }
        parameters.abort_callback_user_data = tokenPointer

        let result = profile.languageCode.withCString { language in
            parameters.language = language
            return samples.withUnsafeBufferPointer { audioSamples in
                parameters.initial_prompt = nil
                parameters.carry_initial_prompt = false
                return whisper_full(
                    context,
                    parameters,
                    audioSamples.baseAddress,
                    Int32(audioSamples.count)
                )
            }
        }
        guard !cancellationToken.isCancelled else { throw CancellationError() }
        guard result == 0 else { throw WhisperModelError.transcriptionFailed }

        let count = whisper_full_n_segments(context)
        let transcript = (0..<count).compactMap { index -> String? in
            guard let text = whisper_full_get_segment_text(context, index) else { return nil }
            return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let joinedTranscript = transcript.filter { !$0.isEmpty }.joined(separator: "\n")
        return WhisperTranscriptSanitizer.removingNonSpeechOnlyResult(joinedTranscript)
    }

    static func contextParameters() -> whisper_context_params {
        var parameters = whisper_context_default_params()
        // A Metal allocation failure inside whisper.cpp can terminate the
        // process before the initializer returns, so an in-process GPU→CPU
        // retry cannot make that path safe. CPU inference is still faster than
        // real time on supported Macs and keeps recording data recoverable
        // under memory pressure.
        parameters.use_gpu = false
        return parameters
    }

    static func parameters(for profile: WhisperDecodingProfile) -> whisper_full_params {
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.translate = false
        parameters.no_context = !profile.keepsPreviousTextContext
        parameters.no_timestamps = !profile.generatesSegmentTimestamps
        parameters.single_segment = false
        parameters.token_timestamps = false
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.n_threads = WhisperPerformanceConfiguration.inferenceThreadCount
        parameters.greedy.best_of = profile.greedyBestOf
        return parameters
    }
}
