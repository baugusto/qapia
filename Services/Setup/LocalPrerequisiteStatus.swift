@preconcurrency import AVFoundation
import Combine
import Foundation

public enum LocalPrerequisiteID: String, CaseIterable, Sendable {
    case operatingSystem
    case localStorage
    case microphone
    case whisperModel
    case ollamaRuntime
    case summaryModel
}

public enum LocalPrerequisiteHealth: Equatable, Sendable {
    case checking
    case ready
    case attention
    case unavailable
}

public struct LocalPrerequisiteItem: Identifiable, Equatable, Sendable {
    public let id: LocalPrerequisiteID
    public let title: String
    public let detail: String
    public let health: LocalPrerequisiteHealth

    public init(
        id: LocalPrerequisiteID,
        title: String,
        detail: String,
        health: LocalPrerequisiteHealth
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.health = health
    }
}

/// Single source of truth for the requirements displayed in Settings. The
/// preparation pipeline updates these entries as it validates the same local
/// resources used by transcription and summary generation.
@MainActor
public final class ApplicationPrerequisiteStatus: ObservableObject {
    public static let shared = ApplicationPrerequisiteStatus()

    @Published public private(set) var items: [LocalPrerequisiteItem]

    private init() {
        items = Self.initialItems
        refreshEnvironmentChecks()
    }

    public func refreshEnvironmentChecks() {
        update(
            .operatingSystem,
            detail: "macOS compatível com captura e processamento local.",
            health: .ready
        )

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Qapia", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: applicationSupport,
                withIntermediateDirectories: true
            )
            let writable = FileManager.default.isWritableFile(atPath: applicationSupport.path)
            update(
                .localStorage,
                detail: writable
                    ? "Pasta local disponível para gravações e modelos."
                    : "A pasta local não permite gravação.",
                health: writable ? .ready : .unavailable
            )
        } catch {
            update(
                .localStorage,
                detail: "Não foi possível preparar a pasta local: \(error.localizedDescription)",
                health: .unavailable
            )
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            update(.microphone, detail: "Acesso ao microfone autorizado.", health: .ready)
        case .notDetermined:
            update(
                .microphone,
                detail: "A permissão será solicitada ao iniciar a primeira gravação.",
                health: .attention
            )
        case .denied, .restricted:
            update(
                .microphone,
                detail: "Acesso bloqueado nos Ajustes de Privacidade do macOS.",
                health: .unavailable
            )
        @unknown default:
            update(
                .microphone,
                detail: "Não foi possível confirmar a permissão do microfone.",
                health: .attention
            )
        }
    }

    func beginPreparation() {
        refreshEnvironmentChecks()
        update(.whisperModel, detail: "Verificando o modelo de transcrição…", health: .checking)
        update(.ollamaRuntime, detail: "Aguardando verificação do serviço local…", health: .checking)
        update(.summaryModel, detail: "Aguardando verificação do modelo de resumo…", health: .checking)
    }

    func markWhisperReady() {
        update(.whisperModel, detail: "Modelo Whisper Small validado.", health: .ready)
    }

    func markWhisperFailed(_ message: String) {
        update(.whisperModel, detail: message, health: .unavailable)
    }

    func beginSummaryPreparation(model: String) {
        update(.ollamaRuntime, detail: "Verificando o serviço Ollama local…", health: .checking)
        update(.summaryModel, detail: "Verificando \(model)…", health: .checking)
    }

    func markSummaryReady(model: String) {
        update(.ollamaRuntime, detail: "Serviço Ollama local ativo.", health: .ready)
        update(.summaryModel, detail: "\(model) instalado e disponível.", health: .ready)
    }

    func markSummaryFailed(_ error: Error, model: String) {
        let message = error.localizedDescription
        switch error {
        case OllamaResourceError.modelDownloadFailed:
            update(.ollamaRuntime, detail: "Serviço Ollama local ativo.", health: .ready)
            update(.summaryModel, detail: message, health: .unavailable)
        case OllamaResourceError.unsupportedMac,
             OllamaResourceError.runtimeDownloadFailed,
             OllamaResourceError.runtimeInvalid,
             OllamaResourceError.runtimeDidNotStart:
            update(.ollamaRuntime, detail: message, health: .unavailable)
            update(
                .summaryModel,
                detail: "O modelo será verificado quando o Ollama estiver disponível.",
                health: .attention
            )
        default:
            update(.ollamaRuntime, detail: message, health: .unavailable)
            update(.summaryModel, detail: "Não foi possível validar \(model).", health: .attention)
        }
    }

    private func update(
        _ id: LocalPrerequisiteID,
        detail: String,
        health: LocalPrerequisiteHealth
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let existing = items[index]
        items[index] = LocalPrerequisiteItem(
            id: id,
            title: existing.title,
            detail: detail,
            health: health
        )
    }

    private static let initialItems: [LocalPrerequisiteItem] = [
        .init(
            id: .operatingSystem,
            title: "macOS",
            detail: "Verificando compatibilidade…",
            health: .checking
        ),
        .init(
            id: .localStorage,
            title: "Armazenamento local",
            detail: "Verificando acesso às gravações…",
            health: .checking
        ),
        .init(
            id: .microphone,
            title: "Microfone",
            detail: "Verificando permissão…",
            health: .checking
        ),
        .init(
            id: .whisperModel,
            title: "Transcrição · Whisper",
            detail: "Aguardando verificação…",
            health: .checking
        ),
        .init(
            id: .ollamaRuntime,
            title: "Resumo · Ollama",
            detail: "Aguardando verificação…",
            health: .checking
        ),
        .init(
            id: .summaryModel,
            title: "Modelo de resumo · Qwen",
            detail: "Aguardando verificação…",
            health: .checking
        )
    ]
}
