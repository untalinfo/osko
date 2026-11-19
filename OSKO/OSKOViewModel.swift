//
//  OSKOViewModel.swift
//  OSKO
//
//  Created by Oscar Info Giraldo on 6/11/26.
//

import AppKit
import Combine
import Foundation
import os

@MainActor
protocol OSKOAIManaging: AnyObject {
    var isModelLoaded: Bool { get }
    var isLoading: Bool { get }
    var modelError: String? { get }

    var isModelLoadedPublisher: AnyPublisher<Bool, Never> { get }
    var isLoadingPublisher: AnyPublisher<Bool, Never> { get }
    var modelErrorPublisher: AnyPublisher<String?, Never> { get }

    func loadModel(modelPath: String) async
    func retryLoad() async
    func generateResponse(
        prompt: String,
        history: [ChatMessage],
        context: String,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String
    func extractMemoryObservation(userPrompt: String, aiResponse: String) async -> String?
}

extension OSKOAIManaging {
    func loadModel() async {
        await loadModel(modelPath: AIModelManager.defaultModelPath)
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var text: String
    let isUser: Bool
    let isError: Bool

    init(id: UUID = UUID(), text: String, isUser: Bool, isError: Bool = false) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.isError = isError
    }
}

/// OSKOViewModel is the central coordinator between the AI Engine, Memory, Panel Presence, Gaze, and Voice Senses.
class OSKOViewModel: ObservableObject {
    @Published var userInput: String = ""
    @Published private(set) var chatHistory: [ChatMessage] = []
    @Published private(set) var currentEmotion: OSKOEmotion = .idle
    @Published private(set) var isThinking: Bool = false
    @Published private(set) var isModelLoaded: Bool = false
    @Published private(set) var isModelLoading: Bool = false
    @Published private(set) var modelError: String?

    // Panel expansion & gaze tracking state
    @Published private(set) var isPanelExpanded: Bool = false
    @Published private(set) var eyeGazeOffset: CGSize = .zero

    // Voice senses state (STT & TTS)
    @Published var isVoiceOutputEnabled: Bool = true {
        didSet {
            if !isVoiceOutputEnabled {
                voiceSynthesizer.stopSpeaking()
            } else if !oldValue && !isThinking {
                speakLastAssistantMessage()
            }
        }
    }
    @Published private(set) var isListening: Bool = false
    @Published private(set) var speechPermissionState: OSKOSpeechPermissionState = .notDetermined
    @Published private(set) var speechStatusMessage: String?
    @Published private(set) var activeSpeechLocale: String = "es-MX"

    var enableAutoSendOnSilence: Bool
    var speechSilenceAutoSendDelay: TimeInterval

    var onPanelExpandedChanged: ((Bool) -> Void)?
    var bodyScreenCenterProvider: (() -> NSPoint)?

    private let logger = Logger(subsystem: "com.infodev.OSKO", category: "ViewModel")
    private let aiManager: any OSKOAIManaging
    private let memoryManager: any OSKOMemoryManaging
    let voiceSynthesizer: any OSKOVoiceSynthesizing
    let speechRecognizer: any OSKOSpeechRecognizing

    private(set) var lastResponseTask: Task<Void, Never>?
    private(set) var lastMemoryExtractionTask: Task<Void, Never>?
    private(set) var silenceAutoSendTask: Task<Void, Never>?

    init(
        aiManager: (any OSKOAIManaging)? = nil,
        memoryManager: (any OSKOMemoryManaging)? = nil,
        voiceSynthesizer: (any OSKOVoiceSynthesizing)? = nil,
        speechRecognizer: (any OSKOSpeechRecognizing)? = nil,
        autoLoad: Bool = true,
        isVoiceOutputEnabled: Bool = true,
        enableAutoSendOnSilence: Bool? = nil,
        speechSilenceAutoSendDelay: TimeInterval = 1.4
    ) {
        let resolvedAI = aiManager ?? AIModelManager()
        let resolvedMemory = memoryManager ?? OSKOMemoryManager()
        let resolvedSynthesizer = voiceSynthesizer ?? OSKOVoiceSynthesizer(enableAudioPlayback: autoLoad)
        let resolvedRecognizer = speechRecognizer ?? OSKOSpeechRecognizer()

        self.aiManager = resolvedAI
        self.memoryManager = resolvedMemory
        self.voiceSynthesizer = resolvedSynthesizer
        self.speechRecognizer = resolvedRecognizer
        self.isVoiceOutputEnabled = isVoiceOutputEnabled
        self.enableAutoSendOnSilence = enableAutoSendOnSilence ?? autoLoad
        self.speechSilenceAutoSendDelay = speechSilenceAutoSendDelay

        self.isModelLoaded = resolvedAI.isModelLoaded
        self.isModelLoading = resolvedAI.isLoading
        self.modelError = resolvedAI.modelError
        self.isListening = resolvedRecognizer.isListening
        self.speechPermissionState = resolvedRecognizer.permissionState
        self.speechStatusMessage = resolvedRecognizer.statusMessage
        self.activeSpeechLocale = resolvedRecognizer.activeLocaleIdentifier

        resolvedAI.isModelLoadedPublisher.assign(to: &$isModelLoaded)
        resolvedAI.isLoadingPublisher.assign(to: &$isModelLoading)
        resolvedAI.modelErrorPublisher.assign(to: &$modelError)

        resolvedRecognizer.onTranscriptUpdate = { [weak self] transcript, isFinal in
            guard let self else { return }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.userInput = trimmed
            self.syncSpeechRecognizerState()
            self.scheduleAutoSendAfterSilence(isFinal: isFinal)
        }

        if autoLoad {
            Task {
                await resolvedMemory.warmUp()
                await resolvedAI.loadModel()
            }
        }
    }

    private func scheduleAutoSendAfterSilence(isFinal: Bool) {
        guard enableAutoSendOnSilence else { return }
        silenceAutoSendTask?.cancel()
        let waitDuration = isFinal ? min(0.35, speechSilenceAutoSendDelay) : speechSilenceAutoSendDelay

        silenceAutoSendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.05, waitDuration) * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let currentText = self.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currentText.isEmpty, self.isModelLoaded, !self.isThinking else { return }
            if self.speechRecognizer.isListening {
                self.speechRecognizer.stopListening()
                self.syncSpeechRecognizerState()
            }
            self.sendMessage()
        }
    }

    func retryModelLoad() {
        Task {
            await aiManager.retryLoad()
        }
    }

    func setPanelExpanded(_ expanded: Bool) {
        guard isPanelExpanded != expanded else { return }
        isPanelExpanded = expanded
        onPanelExpandedChanged?(expanded)

        if !expanded {
            silenceAutoSendTask?.cancel()
            silenceAutoSendTask = nil
            speechRecognizer.stopListening()
            voiceSynthesizer.stopSpeaking()
            syncSpeechRecognizerState()
        } else {
            Task { [weak self] in
                guard let self else { return }
                await self.speechRecognizer.handlePanelExpansionChanged(isExpanded: true)
                self.syncSpeechRecognizerState()
            }
        }
    }

    func togglePanelExpanded() {
        setPanelExpanded(!isPanelExpanded)
    }

    func toggleVoiceListening() {
        Task { [weak self] in
            guard let self else { return }
            if !self.speechRecognizer.isListening {
                self.voiceSynthesizer.stopSpeaking()
            }
            await self.speechRecognizer.toggleListening()
            self.syncSpeechRecognizerState()
        }
    }

    func switchSpeechLocale(_ localeIdentifier: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.speechRecognizer.switchLocale(localeIdentifier)
            self.syncSpeechRecognizerState()
        }
    }

    func toggleSpeechLocaleBetweenSpanishAndEnglish() {
        let isSpanish = activeSpeechLocale.lowercased().hasPrefix("es")
        switchSpeechLocale(isSpanish ? "en-US" : "es-CO")
    }

    func speakMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if speechRecognizer.isListening {
            speechRecognizer.stopListening()
            syncSpeechRecognizerState()
        }
        if !isVoiceOutputEnabled {
            isVoiceOutputEnabled = true
        }
        _ = voiceSynthesizer.speak(text: trimmed, emotion: currentEmotion, preferredLanguage: nil)
    }

    func speakLastAssistantMessage() {
        guard let lastAssistant = chatHistory.last(where: { !$0.isUser && !$0.isError }) else {
            return
        }
        speakMessage(lastAssistant.text)
    }

    func handleSpeakerButtonTapped() {
        if voiceSynthesizer.isSpeaking {
            voiceSynthesizer.stopSpeaking()
            return
        }
        if !isVoiceOutputEnabled {
            isVoiceOutputEnabled = true
            return
        }
        if chatHistory.contains(where: { !$0.isUser && !$0.isError }) {
            speakLastAssistantMessage()
        } else {
            isVoiceOutputEnabled.toggle()
        }
    }

    func updateGaze(forCursorScreenPoint cursorPoint: NSPoint, bodyCenterOverride: NSPoint? = nil) {
        let bodyCenter = bodyCenterOverride
            ?? bodyScreenCenterProvider?()
            ?? NSPoint(x: 720, y: 880)
        let target = OSKOGazeMath.targetEyeOffset(
            cursorScreenPoint: cursorPoint,
            bodyScreenCenter: bodyCenter,
            emotion: currentEmotion,
            isThinking: isThinking
        )
        let nextOffset = OSKOGazeMath.interpolateOffset(
            current: eyeGazeOffset,
            target: target
        )
        if abs(nextOffset.width - eyeGazeOffset.width) > 0.015
            || abs(nextOffset.height - eyeGazeOffset.height) > 0.015 {
            eyeGazeOffset = nextOffset
        }
    }

    private func syncSpeechRecognizerState() {
        isListening = speechRecognizer.isListening
        speechPermissionState = speechRecognizer.permissionState
        speechStatusMessage = speechRecognizer.statusMessage
        activeSpeechLocale = speechRecognizer.activeLocaleIdentifier
    }

    func sendMessage() {
        silenceAutoSendTask?.cancel()
        silenceAutoSendTask = nil

        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty, !isThinking, isModelLoaded else { return }

        if speechRecognizer.isListening {
            speechRecognizer.stopListening()
            syncSpeechRecognizerState()
        }
        voiceSynthesizer.stopSpeaking()

        let priorHistory = Array(chatHistory.filter { !$0.isError }.suffix(16))
        chatHistory.append(ChatMessage(text: trimmedInput, isUser: true))
        userInput = ""

        isThinking = true
        currentEmotion = .concentration

        lastResponseTask = Task { [weak self] in
            guard let self else { return }
            let context = await self.memoryManager.retrieveRelevantMemories(for: trimmedInput)
            var rawResponse = ""
            var assistantMessageID: UUID?

            do {
                try Task.checkCancellation()
                let fullResponse = try await self.aiManager.generateResponse(
                    prompt: trimmedInput,
                    history: priorHistory,
                    context: context
                ) { token in
                    rawResponse += token
                    let visibleText = CharacterEngine.stripStreamingTags(from: rawResponse)
                    guard !visibleText.isEmpty else { return }

                    if let existingID = assistantMessageID,
                       let index = self.chatHistory.firstIndex(where: { $0.id == existingID }) {
                        self.chatHistory[index].text = visibleText
                    } else {
                        let newMessage = ChatMessage(text: visibleText, isUser: false)
                        assistantMessageID = newMessage.id
                        self.chatHistory.append(newMessage)
                    }
                }

                let parsed = CharacterEngine.parseResponse(fullResponse)
                if !parsed.cleanText.isEmpty {
                    if let existingID = assistantMessageID,
                       let index = self.chatHistory.firstIndex(where: { $0.id == existingID }) {
                        self.chatHistory[index].text = parsed.cleanText
                    } else {
                        self.chatHistory.append(ChatMessage(text: parsed.cleanText, isUser: false))
                    }
                } else if let existingID = assistantMessageID,
                          let index = self.chatHistory.firstIndex(where: { $0.id == existingID }) {
                    self.chatHistory.remove(at: index)
                }

                self.currentEmotion = parsed.emotion
                self.isThinking = false

                guard !parsed.cleanText.isEmpty else { return }
                let assistantOutput = parsed.cleanText
                if self.isVoiceOutputEnabled {
                    _ = self.voiceSynthesizer.speak(
                        text: assistantOutput,
                        emotion: parsed.emotion,
                        preferredLanguage: nil
                    )
                }

                let aiManager = self.aiManager
                let memoryManager = self.memoryManager
                let logger = self.logger
                self.lastMemoryExtractionTask = Task {
                    if let observation = await aiManager.extractMemoryObservation(
                        userPrompt: trimmedInput,
                        aiResponse: assistantOutput
                    ) {
                        logger.debug("Extracted memory observation")
                        await memoryManager.saveObservation(content: observation)
                    }
                }
            } catch is CancellationError {
                self.isThinking = false
                self.currentEmotion = .idle
                if let existingID = assistantMessageID,
                   let index = self.chatHistory.firstIndex(where: { $0.id == existingID }),
                   self.chatHistory[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.chatHistory.remove(at: index)
                }
            } catch {
                self.logger.error("Failed to generate response: \(error.localizedDescription, privacy: .public)")
                self.isThinking = false
                self.currentEmotion = .empathy

                let fallback = "Hubo un problema en mi procesamiento. ¿Intentamos de nuevo?"
                if let existingID = assistantMessageID,
                   let index = self.chatHistory.firstIndex(where: { $0.id == existingID }) {
                    self.chatHistory[index] = ChatMessage(
                        id: existingID,
                        text: fallback,
                        isUser: false,
                        isError: true
                    )
                } else {
                    self.chatHistory.append(ChatMessage(text: fallback, isUser: false, isError: true))
                }
            }
        }
    }
}
