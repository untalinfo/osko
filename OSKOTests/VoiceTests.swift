//
//  VoiceTests.swift
//  OSKOTests
//

import AppKit
import AVFoundation
import Foundation
import Speech
import Testing
@testable import OSKO

@MainActor
private final class MockSpeechPermissionProvider: OSKOSpeechPermissionProviding {
    var currentState: OSKOSpeechPermissionState
    var requestedState: OSKOSpeechPermissionState
    var requestCount = 0

    init(
        currentState: OSKOSpeechPermissionState = .authorized,
        requestedState: OSKOSpeechPermissionState = .authorized
    ) {
        self.currentState = currentState
        self.requestedState = requestedState
    }

    func currentPermissionState() -> OSKOSpeechPermissionState {
        currentState
    }

    func requestPermissions() async -> OSKOSpeechPermissionState {
        requestCount += 1
        currentState = requestedState
        return requestedState
    }
}

@MainActor
private final class MockAudioCaptureDriver: OSKOAudioCaptureControlling {
    private(set) var isRunning: Bool = false
    var startCount = 0
    var stopCount = 0
    var lastLocaleIdentifier: String?
    var shouldThrowOnStart = false
    private var transcriptHandler: (@MainActor (String, Bool) -> Void)?

    func startCapture(
        localeIdentifier: String,
        onTranscript: @escaping @MainActor (String, Bool) -> Void
    ) throws {
        startCount += 1
        lastLocaleIdentifier = localeIdentifier
        if shouldThrowOnStart {
            isRunning = false
            throw NSError(
                domain: "MockAudioCaptureDriver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Simulated recognizer/audio route unavailable"]
            )
        }
        isRunning = true
        transcriptHandler = onTranscript
    }

    func stopCapture() {
        stopCount += 1
        isRunning = false
        transcriptHandler = nil
    }

    func simulateTranscript(_ text: String, isFinal: Bool) {
        transcriptHandler?(text, isFinal)
    }
}

@MainActor
private final class MockVoiceSynthesizer: OSKOVoiceSynthesizing {
    private(set) var isSpeaking: Bool = false
    private(set) var lastConfiguration: OSKOUtteranceConfiguration?
    var spokenCalls: [(text: String, emotion: OSKOEmotion)] = []
    var stopCallCount = 0

    @discardableResult
    func speak(
        text: String,
        emotion: OSKOEmotion,
        preferredLanguage: String?
    ) -> OSKOUtteranceConfiguration? {
        guard let config = OSKOVocalProfile.utteranceConfiguration(
            for: text,
            vocalState: emotion.vocalState,
            preferredLanguagePrefix: preferredLanguage
        ) else {
            return nil
        }
        if isSpeaking {
            stopSpeaking()
        }
        spokenCalls.append((config.cleanText, emotion))
        lastConfiguration = config
        isSpeaking = true
        return config
    }

    func stopSpeaking() {
        stopCallCount += 1
        isSpeaking = false
    }
}

@Suite("VoiceTests")
struct VoiceTests {
    private let syntheticVoices: [OSKOVoiceDescriptor] = [
        OSKOVoiceDescriptor(identifier: "com.apple.speech.synthesis.voice.Albert", name: "Albert", language: "en-US", qualityRawValue: 1),
        OSKOVoiceDescriptor(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", qualityRawValue: 1),
        OSKOVoiceDescriptor(identifier: "com.apple.voice.compact.es-ES.Monica", name: "Mónica", language: "es-ES", qualityRawValue: 1),
        OSKOVoiceDescriptor(identifier: "com.apple.voice.compact.es-MX.Paulina", name: "Paulina", language: "es-MX", qualityRawValue: 1),
    ]

    @Test("All 4 Character Bible §6 vocal states map deterministically to pairwise-distinct AVSpeechUtterance parameters within mid-low warm bounds")
    func fourVocalStateDistinctUtteranceConfigs() throws {
        var configs: [OSKOUtteranceConfiguration] = []
        for state in OSKOVocalState.allCases {
            let config = try #require(
                OSKOVocalProfile.utteranceConfiguration(
                    for: "No estoy aquí para pensar por ti. Estoy aquí para pensar contigo.",
                    vocalState: state,
                    availableVoices: syntheticVoices
                )
            )
            #expect(config.rate >= AVSpeechUtteranceMinimumSpeechRate)
            #expect(config.rate <= AVSpeechUtteranceMaximumSpeechRate)
            #expect(config.pitchMultiplier >= 0.75 && config.pitchMultiplier <= 1.20)
            #expect(config.preUtteranceDelay >= 0)
            #expect(config.postUtteranceDelay >= 0)

            let utterance = OSKOVocalProfile.makeAVSpeechUtterance(from: config)
            #expect(utterance.speechString == config.cleanText)
            #expect(utterance.rate == config.rate)
            #expect(utterance.pitchMultiplier == config.pitchMultiplier)
            #expect(utterance.preUtteranceDelay == config.preUtteranceDelay)
            #expect(utterance.postUtteranceDelay == config.postUtteranceDelay)
            configs.append(config)
        }

        #expect(configs.count == 4)
        for i in 0..<configs.count {
            for j in (i + 1)..<configs.count {
                let a = configs[i]
                let b = configs[j]
                let identical = (a.rate == b.rate)
                    && (a.pitchMultiplier == b.pitchMultiplier)
                    && (a.preUtteranceDelay == b.preUtteranceDelay)
                    && (a.postUtteranceDelay == b.postUtteranceDelay)
                #expect(!identical)
            }
        }

        let spark = try #require(configs.first { $0.vocalState == .spark })
        let deep = try #require(configs.first { $0.vocalState == .deep })
        #expect(spark.rate > deep.rate)
        #expect(spark.pitchMultiplier > deep.pitchMultiplier)
    }

    @Test("Emotion tags are stripped before TTS utterance creation and empty/tag-only text suppresses TTS")
    @MainActor
    func tagStrippingAndEmptySuppressionBeforeTTS() throws {
        #expect(OSKOVocalProfile.utteranceConfiguration(for: "", vocalState: .organic) == nil)
        #expect(OSKOVocalProfile.utteranceConfiguration(for: "   \n\t  ", vocalState: .spark) == nil)
        #expect(OSKOVocalProfile.utteranceConfiguration(for: "[EMOTION:curious]", vocalState: .spark) == nil)

        let tagged = try #require(
            OSKOVocalProfile.utteranceConfiguration(
                for: "Analicemos esto con calma [EMOTION:concentration]",
                vocalState: .deep,
                availableVoices: syntheticVoices
            )
        )
        #expect(tagged.cleanText == "Analicemos esto con calma")
        #expect(!tagged.cleanText.contains("EMOTION"))

        let synthesizer = OSKOVoiceSynthesizer(enableAudioPlayback: false)
        #expect(synthesizer.speak(text: "   [EMOTION:idle]  ", emotion: .idle) == nil)
        #expect(!synthesizer.isSpeaking)

        let spoken = synthesizer.speak(text: "Hola Oscar [EMOTION:enthusiasm]", emotion: .enthusiasm)
        #expect(spoken?.cleanText == "Hola Oscar")
        #expect(spoken?.vocalState == .spark)
        #expect(synthesizer.isSpeaking)

        // Second speak interrupts and replaces active utterance cleanly
        let interrupted = synthesizer.speak(text: "Let's check this step by step", emotion: .concentration)
        #expect(interrupted?.vocalState == .deep)
        #expect(synthesizer.isSpeaking)

        synthesizer.stopSpeaking()
        #expect(!synthesizer.isSpeaking)
    }

    @Test("Bilingual Spanish and English language detection, LatAm voice priority, and system locale fallback")
    func bilingualLanguageDetectionAndVoiceSelection() throws {
        #expect(OSKOVocalProfile.detectLanguagePrefix(for: "¿Cómo ves dividir el backend?") == "es")
        #expect(OSKOVocalProfile.detectLanguagePrefix(for: "Como estas hoy? Que piensas?") == "es")
        #expect(OSKOVocalProfile.detectLanguagePrefix(for: "Revisa el refactor del NSPanel y el CharacterEngine en Swift antes del PR") == "es")
        #expect(OSKOVocalProfile.detectLanguagePrefix(for: "Wait... what if we look at this from another angle?") == "en")
        #expect(OSKOVocalProfile.detectLanguagePrefix(for: "Hey OSKO, how do we fix the Concentración gaze offset in NotchView?") == "en")

        // Ambiguous short text falls back to systemLocaleIdentifier
        #expect(OSKOVocalProfile.detectLanguagePrefix(for: "hmm...", systemLocaleIdentifier: "es_CO") == "es")
        #expect(OSKOVocalProfile.detectLanguagePrefix(for: "hmm...", systemLocaleIdentifier: "en_US") == "en")
        #expect(OSKOVocalProfile.detectLanguagePrefix(for: "hmm...", systemLocaleIdentifier: "fr_FR") == "en")

        // LatAm Spanish (es-MX) preferred over es-ES; novelty voices excluded for English
        let esVoice = try #require(OSKOVocalProfile.selectVoice(forLanguagePrefix: "es", from: syntheticVoices))
        #expect(esVoice.language == "es-MX")
        #expect(esVoice.name == "Paulina")

        let enVoice = try #require(OSKOVocalProfile.selectVoice(forLanguagePrefix: "en", from: syntheticVoices))
        #expect(enVoice.language == "en-US")
        #expect(enVoice.name == "Samantha")
        #expect(!OSKOVocalProfile.isNoveltyVoiceIdentifier(enVoice.identifier))

        // Empty voice catalog returns nil safely
        #expect(OSKOVocalProfile.selectVoice(forLanguagePrefix: "es", from: []) == nil)

        // Verify across all 4 vocal states in both Spanish and English
        for state in OSKOVocalState.allCases {
            let esConfig = try #require(
                OSKOVocalProfile.utteranceConfiguration(
                    for: "Hola Oscar, pensemos juntos.",
                    vocalState: state,
                    availableVoices: syntheticVoices
                )
            )
            let enConfig = try #require(
                OSKOVocalProfile.utteranceConfiguration(
                    for: "Hello Oscar, let's think together.",
                    vocalState: state,
                    availableVoices: syntheticVoices
                )
            )
            #expect(esConfig.languagePrefix == "es")
            #expect(esConfig.voiceLanguage.hasPrefix("es"))
            #expect(enConfig.languagePrefix == "en")
            #expect(enConfig.voiceLanguage.hasPrefix("en"))
        }
    }

    @Test("STT permission lifecycle handles authorized, asymmetric denied, restricted, and unavailable states safely")
    @MainActor
    func speechPermissionAndErrorFallbacks() async {
        // Asymmetric TCC matrix via LiveSpeechPermissionProvider.combine
        #expect(LiveSpeechPermissionProvider.combine(speech: .authorized, mic: .denied) == .denied)
        #expect(LiveSpeechPermissionProvider.combine(speech: .denied, mic: .authorized) == .denied)
        #expect(LiveSpeechPermissionProvider.combine(speech: .restricted, mic: .authorized) == .restricted)
        #expect(LiveSpeechPermissionProvider.combine(speech: .authorized, mic: .restricted) == .restricted)
        #expect(LiveSpeechPermissionProvider.combine(speech: .authorized, mic: .authorized) == .authorized)

        let supported = ["en-US", "es-MX", "es-ES"]

        // 1. Denied permission
        let deniedPerm = MockSpeechPermissionProvider(currentState: .notDetermined, requestedState: .denied)
        let driver1 = MockAudioCaptureDriver()
        let deniedRecognizer = OSKOSpeechRecognizer(
            preferredLocaleIdentifier: "es-CO",
            supportedLocales: supported,
            permissionProvider: deniedPerm,
            captureDriver: driver1
        )
        await deniedRecognizer.startListening()
        #expect(!deniedRecognizer.isListening)
        #expect(deniedRecognizer.permissionState == .denied)
        #expect(deniedRecognizer.statusMessage != nil)
        #expect(driver1.startCount == 0)

        // 2. Restricted permission
        let restrictedPerm = MockSpeechPermissionProvider(currentState: .restricted, requestedState: .restricted)
        let restrictedRecognizer = OSKOSpeechRecognizer(
            preferredLocaleIdentifier: "en-US",
            supportedLocales: supported,
            permissionProvider: restrictedPerm,
            captureDriver: driver1
        )
        await restrictedRecognizer.startListening()
        #expect(!restrictedRecognizer.isListening)
        #expect(restrictedRecognizer.permissionState == .restricted)
        #expect(restrictedRecognizer.statusMessage != nil)

        // 3. Unavailable recognizer / audio engine error fallback
        let authPerm = MockSpeechPermissionProvider(currentState: .authorized)
        let failingDriver = MockAudioCaptureDriver()
        failingDriver.shouldThrowOnStart = true
        let failingRecognizer = OSKOSpeechRecognizer(
            preferredLocaleIdentifier: "es-MX",
            supportedLocales: supported,
            permissionProvider: authPerm,
            captureDriver: failingDriver
        )
        await failingRecognizer.startListening()
        #expect(!failingRecognizer.isListening)
        #expect(failingRecognizer.permissionState == .unavailable)
        #expect(failingRecognizer.statusMessage?.contains("Simulated") == true)
    }

    @Test("STT auto-activation on expand, idempotency, silence guard, locale switch, and ViewModel integration")
    @MainActor
    func speechLifecycleAndViewModelIntegration() async {
        let perm = MockSpeechPermissionProvider(currentState: .authorized)
        let driver = MockAudioCaptureDriver()
        let recognizer = OSKOSpeechRecognizer(
            preferredLocaleIdentifier: "es-CO",
            supportedLocales: ["en-US", "es-MX", "es-ES"],
            permissionProvider: perm,
            captureDriver: driver,
            autoActivateOnExpand: true
        )
        let synth = MockVoiceSynthesizer()
        let vm = OSKOViewModel(
            voiceSynthesizer: synth,
            speechRecognizer: recognizer,
            autoLoad: false
        )

        #expect(recognizer.activeLocaleIdentifier == "es-MX")
        #expect(!vm.isListening)

        // Expanding panel auto-activates STT when authorized
        vm.setPanelExpanded(true)
        try? await Task.sleep(nanoseconds: 25_000_000)
        #expect(recognizer.isListening)
        #expect(driver.startCount == 1)

        // Double startListening is idempotent
        await recognizer.startListening()
        #expect(driver.startCount == 1)

        // Silence / whitespace transcript is ignored without submitting or mutating userInput
        driver.simulateTranscript("   \n  ", isFinal: false)
        #expect(vm.userInput.isEmpty)
        #expect(vm.chatHistory.isEmpty)

        // Valid partial and final transcripts populate userInput cleanly
        driver.simulateTranscript("Hola OSKO piensa conmigo", isFinal: true)
        #expect(vm.userInput == "Hola OSKO piensa conmigo")
        #expect(!recognizer.isListening)

        // Runtime locale switch ES <-> EN tears down prior capture and restarts in new locale
        await recognizer.startListening()
        #expect(recognizer.isListening)
        await recognizer.switchLocale("en-US")
        #expect(recognizer.activeLocaleIdentifier == "en-US")
        #expect(driver.lastLocaleIdentifier == "en-US")
        #expect(recognizer.isListening)

        // Collapsing panel immediately stops STT and TTS
        _ = synth.speak(text: "Testing speech", emotion: .curious, preferredLanguage: "en")
        #expect(synth.isSpeaking)
        vm.setPanelExpanded(false)
        #expect(!recognizer.isListening)
        #expect(!synth.isSpeaking)

        // verify NSSpeechSynthesizer super-compact to compact voice resolution
        if let sampleConfig = OSKOVocalProfile.utteranceConfiguration(
            for: "Hola Oscar",
            vocalState: .organic,
            availableVoices: [
                OSKOVoiceDescriptor(
                    identifier: "com.apple.voice.super-compact.es-MX.Paulina",
                    name: "Paulina",
                    language: "es-MX",
                    qualityRawValue: 1
                ),
            ]
        ) {
            let resolvedNSVoice = OSKOVocalProfile.resolveNSSpeechVoiceName(
                for: sampleConfig,
                availableVoiceRawValues: ["com.apple.voice.compact.es-MX.Paulina"]
            )
            #expect(resolvedNSVoice?.rawValue == "com.apple.voice.compact.es-MX.Paulina")
        }
    }
}
