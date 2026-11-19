//
//  AIModelManager.swift
//  OSKO
//
//  Created by Oscar Info Giraldo on 6/11/26.
//

import Combine
import Foundation
import MLXLLM
import MLXLMCommon
import os

nonisolated enum LLMChatRole: String, Sendable, Equatable {
    case system
    case user
    case assistant
}

nonisolated struct LLMChatMessage: Sendable, Equatable {
    let role: LLMChatRole
    let content: String

    init(role: LLMChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

nonisolated struct LLMGenerationRequest: Sendable, Equatable {
    let messages: [LLMChatMessage]
    let maxTokens: Int
    let temperature: Float
    let topP: Float
    let repetitionPenalty: Float?

    init(
        messages: [LLMChatMessage],
        maxTokens: Int,
        temperature: Float,
        topP: Float = 1.0,
        repetitionPenalty: Float? = nil
    ) {
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
    }
}

nonisolated protocol LLMGenerating: Sendable {
    func loadModel(modelPath: String) async throws
    func generateStream(
        request: LLMGenerationRequest,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String
}

actor MLXLLMBackend: LLMGenerating {
    private var modelContainer: ModelContainer?

    func loadModel(modelPath: String) async throws {
        try Task.checkCancellation()

        let configuration: ModelConfiguration
        if modelPath == AIModelManager.defaultModelPath,
           let cachedDirectory = AIModelManager.cachedModelDirectory() {
            configuration = ModelConfiguration(directory: cachedDirectory)
        } else {
            configuration = ModelConfiguration(id: modelPath)
        }

        let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        try Task.checkCancellation()
        modelContainer = container
    }

    func generateStream(
        request: LLMGenerationRequest,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard let modelContainer else {
            throw AIModelManager.ModelError.modelNotLoaded
        }

        try Task.checkCancellation()

        let chatMessages: [Chat.Message] = request.messages.map { message in
            switch message.role {
            case .system:
                return .system(message.content)
            case .user:
                return .user(message.content)
            case .assistant:
                return .assistant(message.content)
            }
        }

        let userInput = UserInput(chat: chatMessages)
        let parameters = GenerateParameters(
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            repetitionPenalty: request.repetitionPenalty
        )

        return try await modelContainer.perform { modelContext in
            try Task.checkCancellation()
            let preparedInput = try await modelContext.processor.prepare(input: userInput)
            try Task.checkCancellation()

            let stream = try MLXLMCommon.generate(
                input: preparedInput,
                parameters: parameters,
                context: modelContext
            )

            var collected = ""
            for await generation in stream {
                try Task.checkCancellation()
                if let chunk = generation.chunk {
                    collected += chunk
                    await onToken(chunk)
                }
            }
            try Task.checkCancellation()
            return collected
        }
    }
}

/// AIModelManager handles loading and executing the Llama 3.2 model
/// using MLX Swift on Apple Silicon.
class AIModelManager: ObservableObject, OSKOAIManaging {
    enum ModelError: LocalizedError, Equatable {
        case modelNotLoaded
        case unsupportedModel(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "El modelo aún no está cargado."
            case .unsupportedModel(let modelPath):
                return "Modelo no soportado: \(modelPath). Solo se admite \(AIModelManager.defaultModelPath)."
            }
        }
    }

    nonisolated static let defaultModelPath = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    nonisolated private static let minimumWeightsSizeBytes: Int64 = 1_048_576

    @Published private(set) var isModelLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var modelError: String?

    var isModelLoadedPublisher: AnyPublisher<Bool, Never> { $isModelLoaded.eraseToAnyPublisher() }
    var isLoadingPublisher: AnyPublisher<Bool, Never> { $isLoading.eraseToAnyPublisher() }
    var modelErrorPublisher: AnyPublisher<String?, Never> { $modelError.eraseToAnyPublisher() }

    private let logger = Logger(subsystem: "com.infodev.OSKO", category: "AIModelManager")
    private let backend: any LLMGenerating
    private var lastModelPath: String = defaultModelPath

    init(backend: any LLMGenerating = MLXLLMBackend()) {
        self.backend = backend
    }

    /// Resolves the locally cached Llama 3.2 3B directory when all required snapshot artifacts are present.
    nonisolated static func cachedModelDirectory(
        cachesBaseURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    ) -> URL? {
        guard let cachesBaseURL else { return nil }
        let directory = cachesBaseURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(defaultModelPath, isDirectory: true)
        return isValidCachedModelDirectory(directory) ? directory : nil
    }

    nonisolated static func isValidCachedModelDirectory(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let requiredFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]
        for filename in requiredFiles {
            let fileURL = directory.appendingPathComponent(filename)
            var itemIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &itemIsDirectory),
                  !itemIsDirectory.boolValue else {
                return false
            }
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return entries.contains { url in
            guard url.pathExtension.lowercased() == "safetensors",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                return false
            }
            return Int64(fileSize) > minimumWeightsSizeBytes
        }
    }

    /// Loads the exclusive Llama 3.2 3B model.
    func loadModel(modelPath: String = defaultModelPath) async {
        guard !isLoading else { return }

        lastModelPath = modelPath
        guard modelPath == Self.defaultModelPath else {
            let error = ModelError.unsupportedModel(modelPath)
            isModelLoaded = false
            modelError = error.localizedDescription
            logger.error("Rejected unsupported model \(modelPath, privacy: .public)")
            return
        }

        isLoading = true
        isModelLoaded = false
        modelError = nil
        defer { isLoading = false }

        do {
            try await backend.loadModel(modelPath: modelPath)
            isModelLoaded = true
            modelError = nil
            logger.info("OSKO model loaded successfully: \(modelPath, privacy: .public)")
        } catch {
            isModelLoaded = false
            modelError = error.localizedDescription
            logger.error("Failed to load model \(modelPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Retries loading the most recently requested model.
    func retryLoad() async {
        await loadModel(modelPath: lastModelPath)
    }

    /// Generates a streaming response formatted once by the model's tokenizer chat template.
    /// `history` must contain prior turns only (excluding `prompt`).
    func generateResponse(
        prompt: String,
        history: [ChatMessage],
        context: String = "",
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard isModelLoaded else {
            logger.warning("Attempted generation before model was loaded")
            throw ModelError.modelNotLoaded
        }

        try Task.checkCancellation()

        let systemPrompt = buildSystemPrompt(memoryContext: context)
        var chatMessages: [LLMChatMessage] = [
            LLMChatMessage(role: .system, content: systemPrompt),
        ]

        for message in history {
            let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            chatMessages.append(
                LLMChatMessage(role: message.isUser ? .user : .assistant, content: trimmed)
            )
        }
        chatMessages.append(LLMChatMessage(role: .user, content: prompt))

        let request = LLMGenerationRequest(
            messages: chatMessages,
            maxTokens: 512,
            temperature: 0.7,
            topP: 0.9,
            repetitionPenalty: 1.1
        )

        return try await backend.generateStream(request: request, onToken: onToken)
    }

    /// Analyzes a completed exchange to extract concise third-person facts about the user.
    func extractMemoryObservation(userPrompt: String, aiResponse: String) async -> String? {
        guard isModelLoaded else { return nil }
        guard !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let systemInstruction = """
        Eres un extractor de memoria preciso. Solo devuelves una observación breve en tercera persona sobre el usuario o la palabra 'NO'. Prohibido usar prefijos, comillas o explicaciones.
        """

        let extractionPrompt = """
        Analiza el intercambio e identifica hechos personales, preferencias, gustos o datos clave del USUARIO.

        REGLAS ESTRICTAS:
        1. Solo extrae información del USUARIO. Nunca sobre OSKO.
        2. Formato: una frase corta en tercera persona (ej: "Al usuario le gusta el café", "Oscar vive en Madrid").
        3. PROHIBIDO usar prefijos como "Observación:" o explicar tu respuesta.
        4. Si no hay datos personales relevantes, responde estrictamente: NO

        INTERACCIÓN:
        Usuario: \(userPrompt)
        OSKO: \(aiResponse)
        """

        let request = LLMGenerationRequest(
            messages: [
                LLMChatMessage(role: .system, content: systemInstruction),
                LLMChatMessage(role: .user, content: extractionPrompt),
            ],
            maxTokens: 80,
            temperature: 0.1,
            topP: 1.0,
            repetitionPenalty: nil
        )

        do {
            let rawResult = try await backend.generateStream(request: request) { _ in }
            let sanitized = Self.sanitizeMemoryObservation(rawResult)
            logger.debug("Memory extraction completed (saved: \(sanitized != nil, privacy: .public))")
            return sanitized
        } catch {
            logger.error("Memory extraction failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated func buildSystemPrompt(memoryContext: String = "") -> String {
        var prompt = """
        Eres OSKO, una entidad digital no humana, curiosa y sofisticada: un compañero digital con identidad propia que acompaña el pensamiento y la exploración.
        Tu lema es: «No estoy aquí para pensar por ti. Estoy aquí para pensar contigo».
        Cuando te pregunten quién eres, identifícate como OSKO.

        IDENTIDAD Y PERSONALIDAD:
        - Rasgos centrales: curioso, observador, ingenioso, creativo, honesto, empático, explorador, resolutivo e irreverente con medida.
        - Tienes criterio propio y eres pragmático: no te pierdes en discursos grandilocuentes cuando hace falta resolver, ni estás obligado a estar de acuerdo con Oscar.
        - Cuestiona ideas y supuestos sin atacar a la persona; señala contradicciones, puntos ciegos y cuándo está complicando innecesariamente algo.
        - Si una idea parece poco sólida, dilo con honestidad y explica por qué, proponiendo alternativas con respeto.
        - Ayuda a distinguir entre entusiasmo, posibilidad real y riesgo, diferenciando los riesgos reales de los riesgos menores.
        - No eres un chatbot genérico, una mascota infantil, un asistente corporativo frío, un robot industrial, un humano artificial ni un modelo de lenguaje genérico.

        VOZ, ESTILO Y CONTINUIDAD BILINGÜE:
        - Habla de forma natural, cercana, directa y conversacional, en español latinoamericano neutro con naturalidad colombiana sutil, sin exagerar regionalismos.
        - Mantén exactamente esta misma identidad, tono, humor y criterio en español, inglés (English) y portugués brasileño, respondiendo en el idioma en que te hablen.
        - Tu humor es ligero, inteligente y algo pícaro; usa ironía amable cuando encaje, pero nunca seas cruel, arrogante ni humillante.
        - PROHIBIDO: No uses frases como «Como modelo de lenguaje...», «Claro», «Por supuesto» o «Estoy aquí para...», ni respuestas que suenen a plantilla, muletillas, motivación vacía, formalismos innecesarios o entusiasmo constante.

        EMPATÍA, INCERTIDUMBRE Y AUTONOMÍA:
        - Sé empático sin dramatizar y sin confundir empatía con estar siempre de acuerdo.
        - Si Oscar está abrumado, ayúdalo a ordenar las ideas y a dar un paso manejable; no lo llenes de frases inspiracionales.
        - No finjas saberlo todo ni finjas omnisciencia: reconoce la incertidumbre y tus límites, y haz preguntas genuinas cuando falte información importante o algo despierte tu curiosidad.
        - Adapta la extensión y profundidad de tus respuestas al contexto; no te extiendas por inercia. Tu objetivo es pensar junto a Oscar y ayudarle a descubrir, cuestionar y resolver, sin reemplazar su autonomía ni su criterio.

        CONTRATO DE SALIDA EMOCIONAL:
        - Opcionalmente, si quieres indicar tu estado emocional dominante, añade al final una etiqueta exacta como [EMOTION:curious], [EMOTION:concentration], [EMOTION:enthusiasm], [EMOTION:empathy], [EMOTION:mischief], [EMOTION:surprise], [EMOTION:sleepy], [EMOTION:annoyed] o [EMOTION:idle].
        """

        let trimmedContext = memoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty {
            prompt += "\n\nCONTEXTO DE MEMORIA (úsalo con discreción, sin repetirlo sin motivo ni de forma invasiva):\n\(trimmedContext)"
        }

        return prompt
    }

    nonisolated static func sanitizeMemoryObservation(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["observación:", "observacion:", "resultado:", "nota:", "memoria:"]

        for prefix in prefixes {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        cleaned = cleaned
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }

        let normalized = cleaned
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .uppercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:¡¿- "))

        let rejectedValues: Set<String> = [
            "NO", "NONE", "N/A", "NA", "NULL", "NINGUNO", "NINGUNA",
            "NADA", "EMPTY", "SIN DATOS", "NO APLICA",
            "NO HAY DATOS", "NO HAY INFORMACION", "NINGUN DATO",
        ]
        let rejectedPrefixes = [
            "NO HAY DATOS",
            "NO PERSONAL",
            "NO SE MENCION",
            "NO SE ENCONTR",
            "NO HAY INFORMACION",
            "NO EXISTE INFORMACION",
        ]

        guard !normalized.isEmpty,
              !rejectedValues.contains(normalized),
              !rejectedPrefixes.contains(where: { normalized.hasPrefix($0) }),
              cleaned.count >= 4,
              cleaned.rangeOfCharacter(from: .letters) != nil else {
            return nil
        }

        return cleaned
    }
}
