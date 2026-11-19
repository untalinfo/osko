//
//  AIModelManagerTests.swift
//  OSKOTests
//

import Combine
import Foundation
import Testing
@testable import OSKO

private enum MockBackendError: LocalizedError {
    case loadFailed
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed:
            return "Simulated model load failure"
        case .generationFailed:
            return "Simulated generation failure"
        }
    }
}

private actor MockLLMBackend: LLMGenerating {
    var loadRequests: [String] = []
    var generateRequests: [LLMGenerationRequest] = []
    var loadError: Error?
    var loadDelayNanoseconds: UInt64 = 0
    var generateError: Error?
    var chunksToStream: [String] = []
    var streamDelayNanoseconds: UInt64 = 0
    var extractionResponse: String = "NO"

    func configureLoad(error: Error? = nil, delayNanoseconds: UInt64 = 0) {
        self.loadError = error
        self.loadDelayNanoseconds = delayNanoseconds
    }

    func configureGeneration(
        chunks: [String],
        error: Error? = nil,
        delayNanoseconds: UInt64 = 0,
        extractionResponse: String = "NO"
    ) {
        self.chunksToStream = chunks
        self.generateError = error
        self.streamDelayNanoseconds = delayNanoseconds
        self.extractionResponse = extractionResponse
    }

    func loadModel(modelPath: String) async throws {
        loadRequests.append(modelPath)
        if loadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }
        if let loadError {
            throw loadError
        }
    }

    func generateStream(
        request: LLMGenerationRequest,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        generateRequests.append(request)
        if let generateError {
            throw generateError
        }

        // Memory extraction requests use maxTokens == 80 and temperature == 0.1
        if request.maxTokens == 80 && request.temperature <= 0.2 {
            return extractionResponse
        }

        var collected = ""
        for chunk in chunksToStream {
            if streamDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: streamDelayNanoseconds)
            }
            try Task.checkCancellation()
            collected += chunk
            await onToken(chunk)
        }
        try Task.checkCancellation()
        return collected
    }
}

@MainActor
private final class MockAIManager: OSKOAIManaging {
    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var modelError: String?

    var isModelLoadedPublisher: AnyPublisher<Bool, Never> { $isModelLoaded.eraseToAnyPublisher() }
    var isLoadingPublisher: AnyPublisher<Bool, Never> { $isLoading.eraseToAnyPublisher() }
    var modelErrorPublisher: AnyPublisher<String?, Never> { $modelError.eraseToAnyPublisher() }

    var recordedPrompts: [String] = []
    var recordedHistories: [[ChatMessage]] = []
    var recordedContexts: [String] = []
    var retryLoadCount = 0

    var chunksToStream: [String] = []
    var streamDelayNanoseconds: UInt64 = 0
    var generateError: Error?
    var extractedObservation: String?
    var extractionCalls: [(prompt: String, response: String)] = []

    func loadModel(modelPath: String) async {
        isModelLoaded = true
        modelError = nil
    }

    func retryLoad() async {
        retryLoadCount += 1
        isModelLoaded = true
        modelError = nil
    }

    func generateResponse(
        prompt: String,
        history: [ChatMessage],
        context: String,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        recordedPrompts.append(prompt)
        recordedHistories.append(history)
        recordedContexts.append(context)

        if let generateError {
            throw generateError
        }

        var collected = ""
        for chunk in chunksToStream {
            if streamDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: streamDelayNanoseconds)
            }
            try Task.checkCancellation()
            collected += chunk
            onToken(chunk)
        }
        try Task.checkCancellation()
        return collected
    }

    func extractMemoryObservation(userPrompt: String, aiResponse: String) async -> String? {
        extractionCalls.append((userPrompt, aiResponse))
        return extractedObservation
    }
}

@Suite("AIModelManager")
struct AIModelManagerTests {
    private func makeIsolatedTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AIModelManagerTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func populateCachedModel(
        under cachesRoot: URL,
        includeTokenizer: Bool = true,
        includeTokenizerConfig: Bool = true,
        weightsByteCount: Int? = 1_100_000
    ) throws -> URL {
        let modelDir = cachesRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(AIModelManager.defaultModelPath, isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))
        if includeTokenizer {
            try Data("{}".utf8).write(to: modelDir.appendingPathComponent("tokenizer.json"))
        }
        if includeTokenizerConfig {
            try Data("{}".utf8).write(to: modelDir.appendingPathComponent("tokenizer_config.json"))
        }
        if let weightsByteCount {
            let weights = Data(repeating: 0x1, count: weightsByteCount)
            try weights.write(to: modelDir.appendingPathComponent("model.safetensors"))
        }
        return modelDir
    }

    @Test("defaultModelPath exclusively targets Llama 3.2 3B 4-bit and resolves cache validation")
    func defaultModelPathAndCacheResolution() throws {
        #expect(AIModelManager.defaultModelPath == "mlx-community/Llama-3.2-3B-Instruct-4bit")

        let root = makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AIModelManager.cachedModelDirectory(cachesBaseURL: root) == nil)

        let validDir = try populateCachedModel(under: root)
        #expect(AIModelManager.cachedModelDirectory(cachesBaseURL: root) == validDir)

        let missingTokenizerRoot = makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: missingTokenizerRoot) }
        _ = try populateCachedModel(under: missingTokenizerRoot, includeTokenizer: false)
        #expect(AIModelManager.cachedModelDirectory(cachesBaseURL: missingTokenizerRoot) == nil)

        let missingConfigRoot = makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: missingConfigRoot) }
        _ = try populateCachedModel(under: missingConfigRoot, includeTokenizerConfig: false)
        #expect(AIModelManager.cachedModelDirectory(cachesBaseURL: missingConfigRoot) == nil)

        let tinyWeightsRoot = makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: tinyWeightsRoot) }
        _ = try populateCachedModel(under: tinyWeightsRoot, weightsByteCount: 512)
        #expect(AIModelManager.cachedModelDirectory(cachesBaseURL: tinyWeightsRoot) == nil)

        let noWeightsRoot = makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: noWeightsRoot) }
        _ = try populateCachedModel(under: noWeightsRoot, weightsByteCount: nil)
        #expect(AIModelManager.cachedModelDirectory(cachesBaseURL: noWeightsRoot) == nil)
    }

    @Test("buildSystemPrompt unifies Character Bible and Modelfile clauses and conditional memory context")
    @MainActor
    func unifiedSystemPromptSpec() {
        let manager = AIModelManager(backend: MockLLMBackend())

        let promptWithoutMemory = manager.buildSystemPrompt(memoryContext: "   \n\t  ")
        #expect(!promptWithoutMemory.contains("CONTEXTO DE MEMORIA"))

        let requiredClauses = [
            "OSKO",
            "entidad digital no humana, curiosa y sofisticada",
            "No estoy aquí para pensar por ti. Estoy aquí para pensar contigo",
            "curioso",
            "observador",
            "ingenioso",
            "creativo",
            "honesto",
            "empático",
            "explorador",
            "resolutivo",
            "irreverente con medida",
            "criterio propio",
            "pragmático",
            "Cuestiona ideas y supuestos sin atacar a la persona",
            "contradicciones",
            "poco sólida",
            "explica por qué",
            "entusiasmo, posibilidad real y riesgo",
            "riesgos reales",
            "riesgos menores",
            "chatbot genérico",
            "mascota infantil",
            "asistente corporativo",
            "humano artificial",
            "español latinoamericano neutro",
            "colombiana",
            "inglés",
            "portugués brasileño",
            "Como modelo de lenguaje",
            "Claro",
            "Por supuesto",
            "Estoy aquí para",
            "motivación vacía",
            "entusiasmo constante",
            "abrumado",
            "ordenar las ideas",
            "paso manejable",
            "No finjas saberlo todo",
            "incertidumbre",
            "preguntas genuinas",
            "extensión y profundidad",
            "autonomía",
            "[EMOTION:curious]",
            "[EMOTION:concentration]",
            "[EMOTION:enthusiasm]",
            "[EMOTION:empathy]",
            "[EMOTION:mischief]",
            "[EMOTION:surprise]",
            "[EMOTION:sleepy]",
            "[EMOTION:annoyed]",
            "[EMOTION:idle]",
        ]

        for clause in requiredClauses {
            #expect(promptWithoutMemory.contains(clause))
        }

        let promptWithMemory = manager.buildSystemPrompt(memoryContext: "  \n- Oscar vive en Colombia\n ")
        #expect(promptWithMemory.contains("CONTEXTO DE MEMORIA (úsalo con discreción, sin repetirlo sin motivo ni de forma invasiva):"))
        #expect(promptWithMemory.contains("- Oscar vive en Colombia"))
    }

    @Test("loadModel enforces exclusive model ID, manages state, guards concurrency, and supports retryLoad")
    @MainActor
    func loadLifecycleAndRetry() async {
        let backend = MockLLMBackend()
        let manager = AIModelManager(backend: backend)

        #expect(!manager.isModelLoaded)
        #expect(!manager.isLoading)
        #expect(manager.modelError == nil)

        await manager.loadModel(modelPath: "custom/unsupported-model")
        #expect(!manager.isModelLoaded)
        #expect(!manager.isLoading)
        #expect(manager.modelError?.contains("custom/unsupported-model") == true)
        #expect(await backend.loadRequests.isEmpty)

        await backend.configureLoad(error: MockBackendError.loadFailed)
        await manager.loadModel()
        #expect(!manager.isModelLoaded)
        #expect(!manager.isLoading)
        #expect(manager.modelError == MockBackendError.loadFailed.localizedDescription)
        #expect(await backend.loadRequests == [AIModelManager.defaultModelPath])

        await backend.configureLoad(error: nil)
        await manager.retryLoad()
        #expect(manager.isModelLoaded)
        #expect(!manager.isLoading)
        #expect(manager.modelError == nil)
        #expect(await backend.loadRequests == [AIModelManager.defaultModelPath, AIModelManager.defaultModelPath])

        // Concurrency guard while loading
        let slowBackend = MockLLMBackend()
        await slowBackend.configureLoad(error: nil, delayNanoseconds: 60_000_000)
        let concurrentManager = AIModelManager(backend: slowBackend)
        async let firstLoad: Void = concurrentManager.loadModel()
        try? await Task.sleep(nanoseconds: 10_000_000)
        await concurrentManager.loadModel()
        await firstLoad
        #expect(await slowBackend.loadRequests.count == 1)
        #expect(concurrentManager.isModelLoaded)
    }

    @Test("generateResponse validates modelLoaded, builds chat parameters/history, streams tokens, and propagates errors/cancellation")
    @MainActor
    func generateResponseBehavior() async throws {
        let backend = MockLLMBackend()
        let manager = AIModelManager(backend: backend)

        do {
            _ = try await manager.generateResponse(prompt: "Hola", history: [], onToken: { _ in })
            Issue.record("Expected modelNotLoaded error")
        } catch let error as AIModelManager.ModelError {
            #expect(error == .modelNotLoaded)
            #expect(error.localizedDescription == "El modelo aún no está cargado.")
        }

        await manager.loadModel()
        await backend.configureGeneration(chunks: ["Hola ", "Oscar ", "[EMOTION:curious]"])

        let history = [
            ChatMessage(text: "Primer turno", isUser: true),
            ChatMessage(text: "   \n  ", isUser: false),
            ChatMessage(text: "Respuesta previa", isUser: false),
        ]

        var streamedTokens: [String] = []
        let output = try await manager.generateResponse(
            prompt: "¿Seguimos?",
            history: history,
            context: "- Prefiere Swift"
        ) { token in
            streamedTokens.append(token)
        }

        #expect(streamedTokens == ["Hola ", "Oscar ", "[EMOTION:curious]"])
        #expect(output == "Hola Oscar [EMOTION:curious]")

        let requests = await backend.generateRequests
        #expect(requests.count == 1)
        let req = try #require(requests.first)
        #expect(req.maxTokens == 512)
        #expect(req.temperature == 0.7)
        #expect(req.topP == 0.9)
        #expect(req.repetitionPenalty == 1.1)
        #expect(req.messages.count == 4)
        #expect(req.messages[0].role == .system)
        #expect(req.messages[0].content.contains("- Prefiere Swift"))
        #expect(req.messages[1] == LLMChatMessage(role: .user, content: "Primer turno"))
        #expect(req.messages[2] == LLMChatMessage(role: .assistant, content: "Respuesta previa"))
        #expect(req.messages[3] == LLMChatMessage(role: .user, content: "¿Seguimos?"))

        // Error propagation
        await backend.configureGeneration(chunks: [], error: MockBackendError.generationFailed)
        await #expect(throws: MockBackendError.self) {
            _ = try await manager.generateResponse(prompt: "Fallo", history: [], onToken: { _ in })
        }

        // Cancellation propagation
        await backend.configureGeneration(chunks: ["Uno", "Dos", "Tres"], error: nil, delayNanoseconds: 50_000_000)
        let task = Task {
            try await manager.generateResponse(prompt: "Cancelar", history: [], onToken: { _ in })
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("extractMemoryObservation and sanitizeMemoryObservation handle valid facts, rejections, and unloaded state")
    @MainActor
    func memoryExtractionAndSanitization() async {
        let backend = MockLLMBackend()
        let manager = AIModelManager(backend: backend)

        #expect(await manager.extractMemoryObservation(userPrompt: "Me llamo Oscar", aiResponse: "Hola") == nil)
        #expect(await backend.generateRequests.isEmpty)

        await manager.loadModel()
        #expect(await manager.extractMemoryObservation(userPrompt: "   ", aiResponse: "Hola") == nil)
        #expect(await manager.extractMemoryObservation(userPrompt: "Hola", aiResponse: "  \n ") == nil)
        #expect(await backend.generateRequests.isEmpty)

        await backend.configureGeneration(
            chunks: [],
            extractionResponse: "Observación: \"El usuario vive en Colombia\""
        )
        let extracted = await manager.extractMemoryObservation(
            userPrompt: "Vivo en Colombia",
            aiResponse: "Genial"
        )
        #expect(extracted == "El usuario vive en Colombia")
        let req = await backend.generateRequests.last
        #expect(req?.maxTokens == 80)
        #expect(req?.temperature == 0.1)
        #expect(req?.topP == 1.0)
        #expect(req?.repetitionPenalty == nil)

        await backend.configureGeneration(chunks: [], error: MockBackendError.generationFailed)
        #expect(await manager.extractMemoryObservation(userPrompt: "Hola", aiResponse: "Qué tal") == nil)

        // Direct sanitizeMemoryObservation matrix
        let rejectedCases = [
            "", "   ", "NO", "no.", "None", "N/A", "NA", "NULL",
            "Ninguno", "Ninguna", "Nada", "SIN DATOS", "No aplica",
            "No hay datos personales.", "No personal info found",
            "No se menciona información relevante", "No se encontró nada",
            "No hay información suficiente", "No existe información personal",
            "abc", "12345", "!!!!",
        ]
        for rejected in rejectedCases {
            #expect(AIModelManager.sanitizeMemoryObservation(rejected) == nil)
        }

        #expect(AIModelManager.sanitizeMemoryObservation("observacion:  Al usuario le gusta Swift ") == "Al usuario le gusta Swift")
        #expect(AIModelManager.sanitizeMemoryObservation("Resultado: 'Oscar usa macOS'") == "Oscar usa macOS")
        #expect(AIModelManager.sanitizeMemoryObservation("Nota: Prefiere arquitectura hexagonal") == "Prefiere arquitectura hexagonal")
        #expect(AIModelManager.sanitizeMemoryObservation("Memoria: Trabaja con MLX") == "Trabaja con MLX")
    }

    @Test("OSKOViewModel orchestrates DI streaming, tag stripping, emotion updates, windowing, errors, cancellation, and memory")
    @MainActor
    func viewModelDIOrchestration() async {
        let dir = makeIsolatedTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storageURL = dir.appendingPathComponent("osko_memory.json")

        let mockAI = MockAIManager()
        let memory = OSKOMemoryManager(storageURL: storageURL)
        let viewModel = OSKOViewModel(aiManager: mockAI, memoryManager: memory, autoLoad: false)

        // Guard: unloaded model
        viewModel.userInput = "Hola OSKO"
        viewModel.sendMessage()
        #expect(viewModel.chatHistory.isEmpty)

        // Guard: empty input after load
        await mockAI.loadModel(modelPath: AIModelManager.defaultModelPath)
        #expect(viewModel.isModelLoaded)
        viewModel.userInput = "   \n  "
        viewModel.sendMessage()
        #expect(viewModel.chatHistory.isEmpty)

        // Streaming, tag stripping, emotion update, and background memory save
        mockAI.chunksToStream = ["Buen ", "punto ", "[EMOT", "ION:mischief]"]
        mockAI.extractedObservation = "Oscar disfruta diseñar arquitecturas limpias"
        viewModel.userInput = "¿Qué opinas?"
        viewModel.sendMessage()

        #expect(viewModel.isThinking)
        #expect(viewModel.currentEmotion == .concentration)
        #expect(viewModel.userInput == "")

        await viewModel.lastResponseTask?.value
        await viewModel.lastMemoryExtractionTask?.value

        #expect(!viewModel.isThinking)
        #expect(viewModel.currentEmotion == .mischief)
        #expect(viewModel.chatHistory.map(\.text) == ["¿Qué opinas?", "Buen punto"])
        let storedMemories = await memory.retrieveRelevantMemories(for: "arquitecturas")
        #expect(storedMemories.contains("Oscar disfruta diseñar arquitecturas limpias"))

        // Tag-only response should not leave an empty assistant bubble or extract memory
        let callsBeforeTagOnly = mockAI.extractionCalls.count
        mockAI.chunksToStream = ["  [EMOTION:curious]  "]
        viewModel.userInput = "Solo emoción"
        viewModel.sendMessage()
        await viewModel.lastResponseTask?.value
        #expect(viewModel.currentEmotion == .curious)
        #expect(viewModel.chatHistory.count == 3)
        #expect(mockAI.extractionCalls.count == callsBeforeTagOnly)

        // Error fallback appends isError message and switches to .empathy
        mockAI.generateError = MockBackendError.generationFailed
        viewModel.userInput = "Provocar fallo"
        viewModel.sendMessage()
        await viewModel.lastResponseTask?.value
        #expect(!viewModel.isThinking)
        #expect(viewModel.currentEmotion == .empathy)
        #expect(viewModel.chatHistory.last?.isError == true)
        #expect(viewModel.chatHistory.last?.text == "Hubo un problema en mi procesamiento. ¿Intentamos de nuevo?")

        // History windowing: excludes isError messages and caps priorHistory at 16
        mockAI.generateError = nil
        mockAI.chunksToStream = ["Ok"]
        for index in 1...18 {
            viewModel.userInput = "Mensaje \(index)"
            viewModel.sendMessage()
            await viewModel.lastResponseTask?.value
            await viewModel.lastMemoryExtractionTask?.value
        }
        let lastHistory = mockAI.recordedHistories.last ?? []
        #expect(lastHistory.count == 16)
        #expect(lastHistory.allSatisfy { !$0.isError })

        // Cancellation resets thinking & idle without appending an error message
        let countBeforeCancel = viewModel.chatHistory.count
        mockAI.chunksToStream = ["Uno", "Dos"]
        mockAI.streamDelayNanoseconds = 60_000_000
        viewModel.userInput = "Cancelar esto"
        viewModel.sendMessage()
        try? await Task.sleep(nanoseconds: 15_000_000)
        viewModel.lastResponseTask?.cancel()
        await viewModel.lastResponseTask?.value
        #expect(!viewModel.isThinking)
        #expect(viewModel.currentEmotion == .idle)
        #expect(viewModel.chatHistory.count == countBeforeCancel + 1)
        #expect(viewModel.chatHistory.last?.isError == false)

        // retryModelLoad delegates to aiManager
        mockAI.isModelLoaded = false
        mockAI.modelError = "Failed"
        viewModel.retryModelLoad()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(mockAI.retryLoadCount == 1)
        #expect(viewModel.isModelLoaded)
        #expect(viewModel.modelError == nil)
    }
}

@Suite("AIModelManager Cached Live MLX", .serialized)
struct AIModelManagerLiveCacheTests {
    @Test("Conditional real Llama 3.2 generation from local cache without network download")
    @MainActor
    func conditionalCachedLlama32Generation() async throws {
        guard AIModelManager.cachedModelDirectory() != nil else {
            return
        }
        guard ProcessInfo.processInfo.environment["OSKO_RUN_LIVE_MLX_TESTS"] == "1" else {
            return
        }

        let manager = AIModelManager()
        await manager.loadModel()

        #expect(manager.isModelLoaded)
        #expect(!manager.isLoading)
        #expect(manager.modelError == nil)

        var chunkCount = 0
        let rawResponse = try await manager.generateResponse(
            prompt: "Responde en una frase muy corta: ¿quién eres?",
            history: [],
            context: ""
        ) { _ in
            chunkCount += 1
        }

        #expect(chunkCount >= 1)
        let parsed = CharacterEngine.parseResponse(rawResponse)
        #expect(!parsed.cleanText.isEmpty)

        _ = await manager.extractMemoryObservation(
            userPrompt: "Me llamo Oscar y vivo en Colombia",
            aiResponse: parsed.cleanText
        )
    }
}
