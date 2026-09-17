import Foundation

public protocol SummaryResourcePreparing: Sendable {
    func prepare() async throws
}

public enum OllamaModelChoice: String, CaseIterable, Identifiable, Sendable {
    case fourB = "4b"
    case nineB = "9b"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fourB: "Qwen 3.5 · 4B"
        case .nineB: "Qwen 3.5 · 9B"
        }
    }

    public var detail: String {
        switch self {
        case .fourB: "Mais leve e rápido; recomendado para Macs com menos memória."
        case .nineB: "Maior qualidade; recomendado para Macs com mais memória disponível."
        }
    }

    public var modelName: String {
        switch self {
        case .fourB: "qwen3.5:4b-q4_K_M"
        case .nineB: "qwen3.5:9b-q4_K_M"
        }
    }
}

public enum OllamaModelPreference {
    public static let defaultsKey = "qapia.summary.ollamaModel"

    public static func selectedChoice(defaults: UserDefaults = .standard) -> OllamaModelChoice {
        guard let stored = defaults.string(forKey: defaultsKey),
              let choice = OllamaModelChoice(rawValue: stored) else {
            return .fourB
        }
        return choice
    }

    public static func select(
        _ choice: OllamaModelChoice,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(choice.rawValue, forKey: defaultsKey)
    }
}

public enum OllamaModelPolicy {
    private static let gibibyte: UInt64 = 1_073_741_824

    /// Chooses the largest Qwen 3.5 quantization that leaves enough unified
    /// memory for macOS, the QAP.ia process and Ollama's context cache.
    public static func recommendedModel(physicalMemoryBytes: UInt64) -> String {
        switch physicalMemoryBytes {
        case (48 * gibibyte)...:
            return "qwen3.5:27b-q4_K_M"
        case (24 * gibibyte)..<(48 * gibibyte):
            return "qwen3.5:9b-q4_K_M"
        case (12 * gibibyte)..<(24 * gibibyte):
            return "qwen3.5:4b-q4_K_M"
        default:
            return "qwen3.5:2b-q4_K_M"
        }
    }

    static func preferredInstalledModel(
        from installedNames: [String],
        physicalMemoryBytes: UInt64
    ) -> String? {
        let usable = installedNames.filter {
            let normalized = $0.lowercased()
            return !normalized.contains("embed") &&
                !normalized.contains("cloud") &&
                !normalized.contains("vision")
        }
        let recommended = recommendedModel(physicalMemoryBytes: physicalMemoryBytes)
        let aliases = modelAliases(for: recommended)
        if let exact = usable.first(where: { installed in
            aliases.contains { installed.caseInsensitiveCompare($0) == .orderedSame }
        }) {
            return exact
        }

        let fallbackOrder: [String]
        if recommended.contains(":27b") {
            fallbackOrder = ["9b", "4b", "2b", "0.8b"]
        } else if recommended.contains(":9b") {
            fallbackOrder = ["4b", "2b", "0.8b"]
        } else if recommended.contains(":4b") {
            fallbackOrder = ["2b", "0.8b"]
        } else {
            fallbackOrder = ["0.8b"]
        }
        for size in fallbackOrder {
            if let match = usable.first(where: {
                $0.lowercased().contains("qwen3.5:\(size)")
            }) {
                return match
            }
        }
        return usable.first(where: { $0.lowercased().contains("qwen3.5:") })
            ?? usable.first
    }

    static func isRecommendedModelInstalled(
        _ installedNames: [String],
        recommendedModel: String
    ) -> Bool {
        let aliases = modelAliases(for: recommendedModel)
        return installedNames.contains { installed in
            aliases.contains { installed.caseInsensitiveCompare($0) == .orderedSame }
        }
    }

    private static func modelAliases(for model: String) -> [String] {
        var aliases = [model]
        if model.hasSuffix("-q4_K_M") {
            aliases.append(String(model.dropLast("-q4_K_M".count)))
        }
        return aliases
    }
}

public enum OllamaResourceError: LocalizedError, Sendable {
    case unsupportedMac
    case runtimeDownloadFailed(String)
    case runtimeInvalid
    case runtimeDidNotStart
    case modelDownloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedMac:
            return "O resumo local requer macOS 14 ou posterior em um Mac compatível."
        case let .runtimeDownloadFailed(message):
            return "Não foi possível preparar o Ollama local: \(message)"
        case .runtimeInvalid:
            return "A instalação local do Ollama não passou pela verificação de integridade."
        case .runtimeDidNotStart:
            return "O mecanismo de resumo local não iniciou. Tente novamente."
        case let .modelDownloadFailed(message):
            return "Não foi possível baixar o modelo de resumo: \(message)"
        }
    }
}

/// Verifies the local Ollama service on every launch, installs the official
/// signed macOS runtime under QAP.ia Application Support when absent, starts
/// its loopback server and pulls a Qwen 3.5 model sized for unified memory.
public actor OllamaResourcePreparationCoordinator: SummaryResourcePreparing {
    public static let shared = OllamaResourcePreparationCoordinator()

    private let client: OllamaClient
    private let runtimeInstaller: OllamaRuntimeInstaller
    private var preparationTask: Task<Void, Error>?
    private var ownedServerProcess: Process?

    init(
        client: OllamaClient = .init(),
        runtimeInstaller: OllamaRuntimeInstaller = .init()
    ) {
        self.client = client
        self.runtimeInstaller = runtimeInstaller
    }

    public func prepare() async throws {
        if let preparationTask {
            return try await preparationTask.value
        }
        let selectedModel = OllamaModelPreference.selectedChoice().modelName
        let task = Task { [client, runtimeInstaller] in
            if !(await client.isServiceAvailable()) {
                let executableURL = try await runtimeInstaller.preparedExecutableURL()
                let process = try runtimeInstaller.startServer(executableURL: executableURL)
                self.retainServerProcess(process)
                try await client.waitUntilAvailable()
            }

            let installed = try await client.installedModelNames()
            guard !OllamaModelPolicy.isRecommendedModelInstalled(
                installed,
                recommendedModel: selectedModel
            ) else { return }
            try await client.pullModel(selectedModel)
        }
        preparationTask = task
        defer { preparationTask = nil }
        return try await task.value
    }

    private func retainServerProcess(_ process: Process) {
        ownedServerProcess = process
    }
}

struct OllamaRuntimeInstaller: Sendable {
    static let officialDownloadURL = URL(string: "https://ollama.com/download/Ollama.dmg")!

    private let applicationSupportURL: URL
    private let downloadURL: URL
    private let session: URLSession

    init(
        applicationSupportURL: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Qapia/Ollama", isDirectory: true),
        downloadURL: URL = Self.officialDownloadURL,
        session: URLSession = .shared
    ) {
        self.applicationSupportURL = applicationSupportURL
        self.downloadURL = downloadURL
        self.session = session
    }

    func preparedExecutableURL() async throws -> URL {
        if let installed = installedExecutableURL() { return installed }
        guard #available(macOS 14.0, *) else { throw OllamaResourceError.unsupportedMac }

        let temporaryDMG: URL
        do {
            let (downloadedURL, response) = try await session.download(from: downloadURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw OllamaResourceError.runtimeDownloadFailed("o servidor não confirmou o download")
            }
            temporaryDMG = FileManager.default.temporaryDirectory
                .appendingPathComponent("Qapia-Ollama-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: downloadedURL, to: temporaryDMG)
        } catch let error as OllamaResourceError {
            throw error
        } catch {
            throw OllamaResourceError.runtimeDownloadFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporaryDMG) }

        let mountPoint = try mount(dmgURL: temporaryDMG)
        defer { try? detach(mountPoint: mountPoint) }
        let sourceApp = mountPoint.appendingPathComponent("Ollama.app", isDirectory: true)
        let sourceExecutable = sourceApp.appendingPathComponent("Contents/Resources/ollama")
        guard FileManager.default.isExecutableFile(atPath: sourceExecutable.path) else {
            throw OllamaResourceError.runtimeInvalid
        }
        try verifySignature(of: sourceApp)

        let destinationApp = applicationSupportURL.appendingPathComponent(
            "Ollama.app",
            isDirectory: true
        )
        let stagingApp = applicationSupportURL.appendingPathComponent(
            ".Ollama.app.staging-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: applicationSupportURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceApp, to: stagingApp)
            try verifySignature(of: stagingApp)
            if FileManager.default.fileExists(atPath: destinationApp.path) {
                try FileManager.default.removeItem(at: destinationApp)
            }
            try FileManager.default.moveItem(at: stagingApp, to: destinationApp)
        } catch {
            try? FileManager.default.removeItem(at: stagingApp)
            throw OllamaResourceError.runtimeDownloadFailed(error.localizedDescription)
        }

        let executable = destinationApp.appendingPathComponent("Contents/Resources/ollama")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw OllamaResourceError.runtimeInvalid
        }
        return executable
    }

    func startServer(executableURL: URL) throws -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:11434"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            throw OllamaResourceError.runtimeDownloadFailed(error.localizedDescription)
        }
    }

    private func installedExecutableURL() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Ollama.app/Contents/Resources/ollama"),
            home.appendingPathComponent("Applications/Ollama.app/Contents/Resources/ollama"),
            applicationSupportURL.appendingPathComponent("Ollama.app/Contents/Resources/ollama"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ollama"),
            URL(fileURLWithPath: "/usr/local/bin/ollama")
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func mount(dmgURL: URL) throws -> URL {
        let output = try run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path]
        )
        guard let plist = try PropertyListSerialization.propertyList(
            from: output,
            options: [],
            format: nil
        ) as? [String: Any],
        let entities = plist["system-entities"] as? [[String: Any]],
        let path = entities.compactMap({ $0["mount-point"] as? String }).last else {
            throw OllamaResourceError.runtimeInvalid
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func detach(mountPoint: URL) throws {
        _ = try run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["detach", mountPoint.path]
        )
    }

    private func verifySignature(of appURL: URL) throws {
        _ = try run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", appURL.path]
        )
        let identity = signatureIdentity(of: appURL)
        guard identity.contains("Identifier=com.electron.ollama"),
              identity.contains("TeamIdentifier=3MU9H2V9Y9") else {
            throw OllamaResourceError.runtimeInvalid
        }
    }

    private func signatureIdentity(of appURL: URL) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", appURL.path]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        } catch {
            return ""
        }
    }

    private func run(executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OllamaResourceError.runtimeDownloadFailed(
                message?.isEmpty == false ? message! : "falha no instalador oficial"
            )
        }
        return output
    }
}
