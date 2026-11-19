//
//  OSKOVoiceManager.swift
//  OSKO
//

import AppKit
import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import Speech
import os

/// Voice descriptor abstraction so unit tests can verify bilingual voice selection deterministically.
nonisolated struct OSKOVoiceDescriptor: Sendable, Equatable {
    let identifier: String
    let name: String
    let language: String
    let qualityRawValue: Int

    init(identifier: String, name: String, language: String, qualityRawValue: Int = 1) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.qualityRawValue = qualityRawValue
    }

    init(voice: AVSpeechSynthesisVoice) {
        self.identifier = voice.identifier
        self.name = voice.name
        self.language = voice.language
        self.qualityRawValue = voice.quality.rawValue
    }
}

/// Deterministic `AVSpeechUtterance` parameter specification for each of OSKO's 4 Character Bible §6 vocal states.
nonisolated struct OSKOUtteranceConfiguration: Sendable, Equatable {
    let vocalState: OSKOVocalState
    let cleanText: String
    let languagePrefix: String
    let voiceIdentifier: String?
    let voiceLanguage: String
    let rate: Float
    let pitchMultiplier: Float
    let volume: Float
    let preUtteranceDelay: TimeInterval
    let postUtteranceDelay: TimeInterval
}

/// Pure vocal state & bilingual language resolver conforming to Character Bible §3 & §6.
nonisolated enum OSKOVocalProfile {
    /// Maps an `OSKOEmotion` to one of the 4 Character Bible §6 vocal states.
    static func vocalState(for emotion: OSKOEmotion) -> OSKOVocalState {
        emotion.vocalState
    }

    /// Returns whether an Apple speech voice identifier belongs to legacy Mac novelty/sound-effect voices.
    static func isNoveltyVoiceIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("com.apple.speech.synthesis.voice.")
    }

    /// Returns available host speech voices filtered by language prefixes (`es`, `en`).
    static func availableHostVoices(prefixes: [String] = ["es", "en"]) -> [OSKOVoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            guard prefixes.contains(where: { voice.language.lowercased().hasPrefix($0.lowercased()) }) else {
                return nil
            }
            return OSKOVoiceDescriptor(voice: voice)
        }
    }

    /// Detects whether `text` should be spoken in Spanish (`"es"`) or English (`"en"`),
    /// using lexical signal words, `NLLanguageRecognizer`, and system locale fallback.
    static func detectLanguagePrefix(
        for text: String,
        systemLocaleIdentifier: String = Locale.current.identifier
    ) -> String {
        let stripped = CharacterEngine.stripEmotionTags(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = stripped.lowercased()
        let padded = " \(lower) "

        let spanishSignals = [
            "¿", "¡", " qué ", " que ", " cómo ", " como ", " estás", " estas",
            "hola", "estoy", "puedo", "para ", " con ", " del ", " en ", " el ",
            " la ", " los ", " las ", " por ", " una ", " pero ", "piensa", "contigo",
            "revisa", "antes", "volvamos", "español", "espanol",
        ]
        let englishSignals = [
            " the ", " what ", " how ", " are ", " with ", " this ", "hello",
            "hey ", "actually", "fix ", "quick ", "let's", "lets ", "switch",
            "english", "wait", "think", "angle", "before", "from ",
        ]

        let esHits = spanishSignals.filter { padded.contains($0) }.count
        let enHits = englishSignals.filter { padded.contains($0) }.count
        if esHits > enHits && esHits >= 1 {
            return "es"
        }
        if enHits > esHits && enHits >= 1 {
            return "en"
        }

        if !stripped.isEmpty {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(stripped)
            if let dominant = recognizer.dominantLanguage {
                if dominant == .spanish { return "es" }
                if dominant == .english { return "en" }
            }
        }

        if systemLocaleIdentifier.lowercased().hasPrefix("es") {
            return "es"
        }
        return "en"
    }

    /// Selects the most natural non-novelty Spanish or English voice from `voices`.
    /// Prioritizes neutral Latin American / Colombian Spanish (`es-CO`, `es-419`, `es-MX`, etc.) before `es-ES`.
    static func selectVoice(
        forLanguagePrefix prefix: String,
        from voices: [OSKOVoiceDescriptor]
    ) -> OSKOVoiceDescriptor? {
        let normalizedPrefix = prefix.lowercased().hasPrefix("es") ? "es" : "en"
        let candidates = voices.filter {
            $0.language.lowercased().hasPrefix(normalizedPrefix)
                && !isNoveltyVoiceIdentifier($0.identifier)
        }
        guard !candidates.isEmpty else {
            return voices.first { $0.language.lowercased().hasPrefix(normalizedPrefix) }
        }

        if normalizedPrefix == "es" {
            let preferredTags = ["es-CO", "es-419", "es-MX", "es-CL", "es-US", "es-AR", "es-PE", "es-ES"]
            for tag in preferredTags {
                let matching = candidates.filter { $0.language.caseInsensitiveCompare(tag) == .orderedSame }
                if let best = matching.max(by: { $0.qualityRawValue < $1.qualityRawValue }) {
                    return best
                }
            }
        } else {
            let preferredTags = ["en-US", "en-GB", "en-AU", "en-CA"]
            for tag in preferredTags {
                let matching = candidates.filter { $0.language.caseInsensitiveCompare(tag) == .orderedSame }
                if let best = matching.max(by: { $0.qualityRawValue < $1.qualityRawValue }) {
                    return best
                }
            }
        }

        return candidates.max(by: { $0.qualityRawValue < $1.qualityRawValue }) ?? candidates.first
    }

    /// Returns distinct, mid-low warm vocal parameters for each of the 4 Character Bible §6 vocal states:
    /// - `organic`: Warm, relaxed, close (`rate: 0.49`, `pitch: 0.96`, `pre: 0.04`, `post: 0.08`)
    /// - `spark`: Curious, enthusiastic, energetic (`rate: 0.54`, `pitch: 1.04`, `pre: 0.01`, `post: 0.04`)
    /// - `deep`: Serene, analytical, focused (`rate: 0.45`, `pitch: 0.90`, `pre: 0.08`, `post: 0.14`)
    /// - `playful`: Wry, ironic, light mischief (`rate: 0.52`, `pitch: 1.01`, `pre: 0.03`, `post: 0.06`)
    static func vocalParameters(for state: OSKOVocalState) -> (
        rate: Float,
        pitchMultiplier: Float,
        volume: Float,
        preUtteranceDelay: TimeInterval,
        postUtteranceDelay: TimeInterval
    ) {
        let rawRate: Float
        let rawPitch: Float
        let volume: Float
        let preDelay: TimeInterval
        let postDelay: TimeInterval

        switch state {
        case .organic:
            rawRate = 0.49
            rawPitch = 0.96
            volume = 0.92
            preDelay = 0.04
            postDelay = 0.08
        case .spark:
            rawRate = 0.54
            rawPitch = 1.04
            volume = 0.98
            preDelay = 0.01
            postDelay = 0.04
        case .deep:
            rawRate = 0.45
            rawPitch = 0.90
            volume = 0.90
            preDelay = 0.08
            postDelay = 0.14
        case .playful:
            rawRate = 0.52
            rawPitch = 1.01
            volume = 0.95
            preDelay = 0.03
            postDelay = 0.06
        }

        let clampedRate = min(
            max(rawRate, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
        let clampedPitch = min(max(rawPitch, 0.75), 1.20)
        return (
            rate: clampedRate,
            pitchMultiplier: clampedPitch,
            volume: min(max(volume, 0.0), 1.0),
            preUtteranceDelay: max(0.0, preDelay),
            postUtteranceDelay: max(0.0, postDelay)
        )
    }

    /// Returns distinct `NSSpeechSynthesizer` words-per-minute rates for each vocal state.
    static func wordsPerMinute(for state: OSKOVocalState) -> Float {
        switch state {
        case .organic:
            return 182.0
        case .spark:
            return 208.0
        case .deep:
            return 158.0
        case .playful:
            return 196.0
        }
    }

    /// Builds a complete, tag-stripped `OSKOUtteranceConfiguration` for `text` and `vocalState`.
    /// Returns `nil` when `text` has no speakable content after stripping `[EMOTION:...]` tags.
    static func utteranceConfiguration(
        for text: String,
        vocalState: OSKOVocalState,
        preferredLanguagePrefix: String? = nil,
        systemLocaleIdentifier: String = Locale.current.identifier,
        availableVoices: [OSKOVoiceDescriptor]? = nil
    ) -> OSKOUtteranceConfiguration? {
        let cleanText = CharacterEngine.stripEmotionTags(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }

        let langPrefix: String
        if let preferredLanguagePrefix, !preferredLanguagePrefix.isEmpty {
            langPrefix = preferredLanguagePrefix.lowercased().hasPrefix("es") ? "es" : "en"
        } else {
            langPrefix = detectLanguagePrefix(
                for: cleanText,
                systemLocaleIdentifier: systemLocaleIdentifier
            )
        }

        let catalog = availableVoices ?? availableHostVoices(prefixes: ["es", "en"])
        let chosenVoice = selectVoice(forLanguagePrefix: langPrefix, from: catalog)
        let fallbackLanguage = langPrefix == "es" ? "es-MX" : "en-US"
        let params = vocalParameters(for: vocalState)

        return OSKOUtteranceConfiguration(
            vocalState: vocalState,
            cleanText: cleanText,
            languagePrefix: langPrefix,
            voiceIdentifier: chosenVoice?.identifier,
            voiceLanguage: chosenVoice?.language ?? fallbackLanguage,
            rate: params.rate,
            pitchMultiplier: params.pitchMultiplier,
            volume: params.volume,
            preUtteranceDelay: params.preUtteranceDelay,
            postUtteranceDelay: params.postUtteranceDelay
        )
    }

    /// Creates a configured `AVSpeechUtterance` from `OSKOUtteranceConfiguration`.
    static func makeAVSpeechUtterance(from config: OSKOUtteranceConfiguration) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: config.cleanText)
        if let identifier = config.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice(language: config.voiceLanguage) {
            utterance.voice = voice
        }
        utterance.rate = config.rate
        utterance.pitchMultiplier = config.pitchMultiplier
        utterance.volume = config.volume
        utterance.preUtteranceDelay = config.preUtteranceDelay
        utterance.postUtteranceDelay = config.postUtteranceDelay
        return utterance
    }

    /// Resolves the best available `NSSpeechSynthesizer.VoiceName` for `config`, mapping `super-compact`
    /// identifiers to working `compact` voices so macOS outputs reliable audio without `AUCrashHandler` / `-10877` errors.
    static func resolveNSSpeechVoiceName(
        for config: OSKOUtteranceConfiguration,
        availableVoiceRawValues: [String] = NSSpeechSynthesizer.availableVoices.map(\.rawValue)
    ) -> NSSpeechSynthesizer.VoiceName? {
        let availableSet = Set(availableVoiceRawValues)

        if let id = config.voiceIdentifier {
            let compactCandidate = id.replacingOccurrences(
                of: "com.apple.voice.super-compact.",
                with: "com.apple.voice.compact."
            )
            if availableSet.contains(compactCandidate) {
                return NSSpeechSynthesizer.VoiceName(rawValue: compactCandidate)
            }
            if availableSet.contains(id) {
                return NSSpeechSynthesizer.VoiceName(rawValue: id)
            }
        }

        if config.languagePrefix.lowercased().hasPrefix("es") {
            let spanishPreferred = [
                "com.apple.voice.compact.es-MX.Paulina",
                "com.apple.voice.compact.es-ES.Monica",
            ]
            for candidate in spanishPreferred where availableSet.contains(candidate) {
                return NSSpeechSynthesizer.VoiceName(rawValue: candidate)
            }
            if let anySpanish = availableVoiceRawValues.first(where: {
                $0.contains(".es-") && !$0.hasPrefix("com.apple.speech.synthesis.voice.")
            }) {
                return NSSpeechSynthesizer.VoiceName(rawValue: anySpanish)
            }
        } else {
            let englishPreferred = [
                "com.apple.voice.compact.en-US.Samantha",
                "com.apple.voice.compact.en-GB.Daniel",
                "com.apple.voice.compact.en-AU.Karen",
            ]
            for candidate in englishPreferred where availableSet.contains(candidate) {
                return NSSpeechSynthesizer.VoiceName(rawValue: candidate)
            }
            if let anyEnglish = availableVoiceRawValues.first(where: {
                $0.contains(".en-") && !$0.hasPrefix("com.apple.speech.synthesis.voice.")
            }) {
                return NSSpeechSynthesizer.VoiceName(rawValue: anyEnglish)
            }
        }

        return NSSpeechSynthesizer.defaultVoice
    }

    /// Resolves the best supported `SFSpeechRecognizer` locale identifier for Spanish or English.
    static func resolveSupportedSpeechLocale(
        preferredLocaleIdentifier: String,
        supportedLocaleIdentifiers: [String] = SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
    ) -> String {
        if let exact = supportedLocaleIdentifiers.first(where: {
            $0.caseInsensitiveCompare(preferredLocaleIdentifier) == .orderedSame
        }) {
            return exact
        }

        let normalized = preferredLocaleIdentifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if normalized.hasPrefix("es") {
            let spanishPriority = ["es-CO", "es-419", "es-MX", "es-US", "es-CL", "es-ES"]
            for candidate in spanishPriority {
                if let match = supportedLocaleIdentifiers.first(where: {
                    $0.replacingOccurrences(of: "_", with: "-").caseInsensitiveCompare(candidate) == .orderedSame
                }) {
                    return match
                }
            }
            if let anySpanish = supportedLocaleIdentifiers.first(where: {
                $0.lowercased().hasPrefix("es")
            }) {
                return anySpanish
            }
        }

        let englishPriority = ["en-US", "en-GB", "en-CA", "en-AU"]
        for candidate in englishPriority {
            if let match = supportedLocaleIdentifiers.first(where: {
                $0.replacingOccurrences(of: "_", with: "-").caseInsensitiveCompare(candidate) == .orderedSame
            }) {
                return match
            }
        }
        if let anyEnglish = supportedLocaleIdentifiers.first(where: {
            $0.lowercased().hasPrefix("en")
        }) {
            return anyEnglish
        }

        return supportedLocaleIdentifiers.first ?? "en-US"
    }
}

// MARK: - TTS Protocol & Implementation

@MainActor
protocol OSKOVoiceSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    var lastConfiguration: OSKOUtteranceConfiguration? { get }

    @discardableResult
    func speak(text: String, emotion: OSKOEmotion, preferredLanguage: String?) -> OSKOUtteranceConfiguration?
    func stopSpeaking()
}

final class OSKOVoiceSynthesizer: NSObject, ObservableObject, OSKOVoiceSynthesizing, NSSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var lastConfiguration: OSKOUtteranceConfiguration?

    private let nsSynthesizer = NSSpeechSynthesizer()
    private let enableAudioPlayback: Bool

    init(enableAudioPlayback: Bool = true) {
        self.enableAudioPlayback = enableAudioPlayback
        super.init()
        nsSynthesizer.delegate = self
    }

    @discardableResult
    func speak(
        text: String,
        emotion: OSKOEmotion,
        preferredLanguage: String? = nil
    ) -> OSKOUtteranceConfiguration? {
        guard let config = OSKOVocalProfile.utteranceConfiguration(
            for: text,
            vocalState: emotion.vocalState,
            preferredLanguagePrefix: preferredLanguage
        ) else {
            return nil
        }

        if nsSynthesizer.isSpeaking || isSpeaking {
            stopSpeaking()
        }

        lastConfiguration = config
        _ = OSKOVocalProfile.makeAVSpeechUtterance(from: config)
        isSpeaking = true

        if enableAudioPlayback {
            if let voiceName = OSKOVocalProfile.resolveNSSpeechVoiceName(for: config) {
                _ = nsSynthesizer.setVoice(voiceName)
            }
            nsSynthesizer.rate = OSKOVocalProfile.wordsPerMinute(for: config.vocalState)
            nsSynthesizer.volume = config.volume
            let started = nsSynthesizer.startSpeaking(config.cleanText)
            if !started {
                isSpeaking = false
            }
        }
        return config
    }

    func stopSpeaking() {
        if nsSynthesizer.isSpeaking {
            nsSynthesizer.stopSpeaking()
        }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
        }
    }
}

// MARK: - STT Protocol & Implementation

nonisolated enum OSKOSpeechPermissionState: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

@MainActor
protocol OSKOSpeechPermissionProviding: Sendable {
    func currentPermissionState() -> OSKOSpeechPermissionState
    func requestPermissions() async -> OSKOSpeechPermissionState
}

struct LiveSpeechPermissionProvider: OSKOSpeechPermissionProviding {
    func currentPermissionState() -> OSKOSpeechPermissionState {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        return Self.combine(speech: speechStatus, mic: micStatus)
    }

    func requestPermissions() async -> OSKOSpeechPermissionState {
        let current = currentPermissionState()
        if current == .denied || current == .restricted {
            return current
        }

        let speechStatus = await Self.requestSpeechAuthorizationNonisolated()
        guard speechStatus == .authorized else {
            return Self.combine(speech: speechStatus, mic: AVCaptureDevice.authorizationStatus(for: .audio))
        }

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        let micStatus: AVAuthorizationStatus = micGranted ? .authorized : .denied
        return Self.combine(speech: speechStatus, mic: micStatus)
    }

    nonisolated private static func requestSpeechAuthorizationNonisolated() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated static func combine(
        speech: SFSpeechRecognizerAuthorizationStatus,
        mic: AVAuthorizationStatus
    ) -> OSKOSpeechPermissionState {
        if speech == .restricted || mic == .restricted {
            return .restricted
        }
        if speech == .denied || mic == .denied {
            return .denied
        }
        if speech == .authorized && mic == .authorized {
            return .authorized
        }
        return .notDetermined
    }
}

@MainActor
protocol OSKOAudioCaptureControlling: AnyObject {
    var isRunning: Bool { get }
    func startCapture(
        localeIdentifier: String,
        onTranscript: @escaping @MainActor (String, Bool) -> Void
    ) throws
    func stopCapture()
}

final class LiveAudioCaptureDriver: OSKOAudioCaptureControlling {
    private(set) var isRunning: Bool = false
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isTapInstalled: Bool = false

    func startCapture(
        localeIdentifier: String,
        onTranscript: @escaping @MainActor (String, Bool) -> Void
    ) throws {
        stopCapture()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw NSError(
                domain: "com.infodev.OSKO.Speech",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Reconocimiento de voz no disponible para \(localeIdentifier)."]
            )
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 && format.sampleRate > 0 else {
            throw NSError(
                domain: "com.infodev.OSKO.Speech",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No se detectó entrada de micrófono activa."]
            )
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true

        Self.installAudioTap(on: inputNode, request: request)
        self.isTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            if isTapInstalled {
                inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            throw error
        }

        self.audioEngine = engine
        self.recognitionRequest = request
        self.isRunning = true

        self.recognitionTask = Self.startRecognitionTask(
            recognizer: recognizer,
            request: request,
            onResult: { text, isFinal in
                Task { @MainActor in
                    onTranscript(text, isFinal)
                }
            },
            onError: { [weak self] in
                Task { @MainActor in
                    self?.stopCapture()
                }
            }
        )
    }

    func stopCapture() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            if isTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isRunning = false
    }

    /// Nonisolated so the CoreAudio real-time tap callback is NOT inferred as `@MainActor`,
    /// avoiding `unsafeForcedSync called from Swift Concurrent context` and dropped audio buffers.
    nonisolated private static func installAudioTap(
        on inputNode: AVAudioInputNode,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            request.append(buffer)
        }
    }

    /// Nonisolated so the `SFSpeechRecognizer` callback executes on its background queue without `@MainActor` forced sync.
    nonisolated private static func startRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onResult: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable () -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                onResult(text, isFinal)
            }
            if error != nil {
                onError()
            }
        }
    }
}

@MainActor
protocol OSKOSpeechRecognizing: AnyObject {
    var isListening: Bool { get }
    var activeLocaleIdentifier: String { get }
    var permissionState: OSKOSpeechPermissionState { get }
    var statusMessage: String? { get }
    var autoActivateOnExpand: Bool { get set }
    var onTranscriptUpdate: (@MainActor (String, Bool) -> Void)? { get set }

    func startListening() async
    func stopListening()
    func toggleListening() async
    func switchLocale(_ localeIdentifier: String) async
    func handlePanelExpansionChanged(isExpanded: Bool) async
}

/// Manages bilingual Speech-to-Text (`SFSpeechRecognizer` + `AVAudioEngine`), permissions, and auto-activation lifecycle.
final class OSKOSpeechRecognizer: ObservableObject, OSKOSpeechRecognizing {
    @Published private(set) var isListening: Bool = false
    @Published private(set) var activeLocaleIdentifier: String
    @Published private(set) var permissionState: OSKOSpeechPermissionState
    @Published private(set) var statusMessage: String?
    @Published var autoActivateOnExpand: Bool

    var onTranscriptUpdate: (@MainActor (String, Bool) -> Void)?

    private let logger = Logger(subsystem: "com.infodev.OSKO", category: "SpeechRecognizer")
    private let permissionProvider: any OSKOSpeechPermissionProviding
    private let captureDriver: any OSKOAudioCaptureControlling
    private let supportedLocales: [String]
    private let allowInteractivePermissionPromptOnExpand: Bool

    init(
        preferredLocaleIdentifier: String = Locale.current.identifier,
        supportedLocales: [String] = SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted(),
        permissionProvider: (any OSKOSpeechPermissionProviding)? = nil,
        captureDriver: (any OSKOAudioCaptureControlling)? = nil,
        autoActivateOnExpand: Bool = true,
        allowInteractivePermissionPromptOnExpand: Bool = false
    ) {
        let resolvedProvider = permissionProvider ?? LiveSpeechPermissionProvider()
        let resolvedDriver = captureDriver ?? LiveAudioCaptureDriver()
        self.permissionProvider = resolvedProvider
        self.captureDriver = resolvedDriver
        self.supportedLocales = supportedLocales
        self.activeLocaleIdentifier = OSKOVocalProfile.resolveSupportedSpeechLocale(
            preferredLocaleIdentifier: preferredLocaleIdentifier,
            supportedLocaleIdentifiers: supportedLocales
        )
        self.permissionState = resolvedProvider.currentPermissionState()
        self.autoActivateOnExpand = autoActivateOnExpand
        self.allowInteractivePermissionPromptOnExpand = allowInteractivePermissionPromptOnExpand
    }

    func startListening() async {
        // Idempotent guard: already listening
        guard !isListening else { return }

        let currentPerm = permissionProvider.currentPermissionState()
        let resolvedPerm: OSKOSpeechPermissionState
        if currentPerm == .notDetermined {
            resolvedPerm = await permissionProvider.requestPermissions()
        } else {
            resolvedPerm = currentPerm
        }
        permissionState = resolvedPerm

        switch resolvedPerm {
        case .authorized:
            do {
                try captureDriver.startCapture(localeIdentifier: activeLocaleIdentifier) { [weak self] transcript, isFinal in
                    self?.handleTranscript(transcript, isFinal: isFinal)
                }
                isListening = captureDriver.isRunning
                statusMessage = nil
            } catch {
                captureDriver.stopCapture()
                isListening = false
                permissionState = .unavailable
                statusMessage = error.localizedDescription
                logger.warning("STT start failed: \(error.localizedDescription, privacy: .public)")
            }
        case .denied:
            isListening = false
            statusMessage = "Permiso de micrófono o voz denegado."
        case .restricted:
            isListening = false
            statusMessage = "Reconocimiento de voz restringido en este equipo."
        case .unavailable, .notDetermined:
            isListening = false
            statusMessage = "Entrada de voz no disponible."
        }
    }

    func stopListening() {
        captureDriver.stopCapture()
        isListening = false
    }

    func toggleListening() async {
        if isListening {
            stopListening()
        } else {
            await startListening()
        }
    }

    func switchLocale(_ localeIdentifier: String) async {
        let wasListening = isListening
        if wasListening {
            stopListening()
        }
        activeLocaleIdentifier = OSKOVocalProfile.resolveSupportedSpeechLocale(
            preferredLocaleIdentifier: localeIdentifier,
            supportedLocaleIdentifiers: supportedLocales
        )
        if wasListening {
            await startListening()
        }
    }

    func handlePanelExpansionChanged(isExpanded: Bool) async {
        if !isExpanded {
            stopListening()
            return
        }
        guard autoActivateOnExpand else { return }
        let currentPerm = permissionProvider.currentPermissionState()
        permissionState = currentPerm
        // Only auto-start on expand when permissions are already authorized (or when test/config explicitly enables prompt on expand),
        // preventing unexpected TCC popups or focus disturbances during headless/non-activating panel expansion.
        if currentPerm == .authorized || allowInteractivePermissionPromptOnExpand {
            await startListening()
        }
    }

    private func handleTranscript(_ transcript: String, isFinal: Bool) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isFinal {
            stopListening()
        }
        onTranscriptUpdate?(trimmed, isFinal)
    }
}
