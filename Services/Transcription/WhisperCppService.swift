@preconcurrency import AVFoundation
import CryptoKit
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

public actor WhisperModelStore {
    public static let shared = WhisperModelStore()

    private let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!
    private let expectedSHA1 = "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
    private let destinationURL: URL
    private var preparationTask: Task<URL, Error>?

    public init(destinationURL: URL? = nil) {
        self.destinationURL = destinationURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Qapia/Whisper/ggml-small.bin")
    }

    public func preparedModelURL() async throws -> URL {
        if let preparationTask {
            return try await preparationTask.value
        }

        let task = Task { try await prepareModel() }
        preparationTask = task
        do {
            let url = try await task.value
            preparationTask = nil
            return url
        } catch {
            preparationTask = nil
            throw error
        }
    }

    private func prepareModel() async throws -> URL {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard try sha1(of: destinationURL) == expectedSHA1 else {
                try FileManager.default.removeItem(at: destinationURL)
                return try await downloadModel()
            }
            return destinationURL
        }
        return try await downloadModel()
    }

    private func downloadModel() async throws -> URL {
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: modelURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw WhisperModelError.downloadFailed("O servidor não confirmou o download.")
            }
            guard try sha1(of: temporaryURL) == expectedSHA1 else {
                throw WhisperModelError.integrityCheckFailed
            }

            let directory = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            return destinationURL
        } catch let error as WhisperModelError {
            throw error
        } catch {
            throw WhisperModelError.downloadFailed(error.localizedDescription)
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

    public init(modelStore: WhisperModelStore = .shared) {
        self.modelStore = modelStore
    }

    public func transcribe(segment: RecordingSegment) async throws -> String {
        let modelURL = try await modelStore.preparedModelURL()
        let samples = try await WhisperAudioDecoder.decodeMonoSamples(from: segment.fileURL)
        return try await Task.detached(priority: .userInitiated) {
            try WhisperEngine.transcribe(samples: samples, modelURL: modelURL)
        }.value
    }
}

private enum WhisperAudioDecoder {
    static func decodeMonoSamples(from fileURL: URL) async throws -> [Float] {
        do {
            let asset = AVURLAsset(url: fileURL)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else {
                throw WhisperModelError.audioDecodingFailed("O arquivo não contém faixas de áudio.")
            }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw WhisperModelError.audioDecodingFailed("Não foi possível combinar as faixas de áudio.")
            }
            reader.add(output)
            guard reader.startReading() else {
                throw WhisperModelError.audioDecodingFailed(
                    reader.error?.localizedDescription ?? "Não foi possível iniciar a leitura do áudio."
                )
            }

            var samples: [Float] = []
            while let sampleBuffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                guard byteCount > 0, byteCount.isMultiple(of: MemoryLayout<Float>.size) else { continue }

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
                    throw WhisperModelError.audioDecodingFailed("Não foi possível copiar as amostras de áudio.")
                }
                samples.append(contentsOf: bufferSamples)
            }

            if reader.status == .failed {
                throw WhisperModelError.audioDecodingFailed(
                    reader.error?.localizedDescription ?? "A leitura do áudio foi interrompida."
                )
            }

            guard !samples.isEmpty else {
                throw WhisperModelError.audioDecodingFailed("O segmento não contém amostras de áudio.")
            }
            return samples
        } catch let error as WhisperModelError {
            throw error
        } catch {
            throw WhisperModelError.audioDecodingFailed(error.localizedDescription)
        }
    }
}

private enum WhisperEngine {
    static func transcribe(samples: [Float], modelURL: URL) throws -> String {
        var contextParameters = whisper_context_default_params()
        contextParameters.use_gpu = true
        let context = modelURL.path.withCString {
            whisper_init_from_file_with_params($0, contextParameters)
        }
        guard let context else { throw WhisperModelError.transcriptionFailed }
        defer { whisper_free(context) }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.translate = false
        parameters.no_context = true
        parameters.no_timestamps = true
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false

        let result = "pt".withCString { language in
            parameters.language = language
            return samples.withUnsafeBufferPointer { audioSamples in
                whisper_full(context, parameters, audioSamples.baseAddress, Int32(audioSamples.count))
            }
        }
        guard result == 0 else { throw WhisperModelError.transcriptionFailed }

        let count = whisper_full_n_segments(context)
        let transcript = (0..<count).compactMap { index -> String? in
            guard let text = whisper_full_get_segment_text(context, index) else { return nil }
            return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return transcript.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
