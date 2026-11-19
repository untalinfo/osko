//
//  CharacterEngineTests.swift
//  OSKOTests
//

import Foundation
import Testing
@testable import OSKO

@Suite("CharacterEngine")
struct CharacterEngineTests {
    @Test("OSKOEmotion exposes all 9 expected cases")
    func allCasesCompleteness() {
        #expect(OSKOEmotion.allCases.count == 9)
        #expect(Set(OSKOEmotion.allCases) == [
            .idle,
            .concentration,
            .enthusiasm,
            .empathy,
            .mischief,
            .surprise,
            .curious,
            .sleepy,
            .annoyed,
        ])
    }

    @Test("parseResponse parses all canonical emotion tags")
    func parseCanonicalTags() {
        for emotion in OSKOEmotion.allCases {
            let input = "[EMOTION:\(emotion.rawValue)] Texto neutral"
            let parsed = CharacterEngine.parseResponse(input)
            #expect(parsed.emotion == emotion)
            #expect(parsed.cleanText == "Texto neutral")
        }
    }

    @Test("parseResponse resolves Spanish and vocal-state aliases with case and whitespace tolerance")
    func parseAliasesAndTolerance() {
        let cases: [(String, OSKOEmotion)] = [
            ("[emotion: organic] Hola", .empathy),
            ("[EMOTION:  SPARK ] Hola", .enthusiasm),
            ("[Emotion:Deep] Hola", .concentration),
            ("[EMOTION:playful] Hola", .mischief),
            ("[EMOTION:reposo] Hola", .idle),
            ("[EMOTION:concentración] Hola", .concentration),
            ("[EMOTION:concentracion] Hola", .concentration),
            ("[EMOTION:entusiasmo] Hola", .enthusiasm),
            ("[EMOTION:empatía] Hola", .empathy),
            ("[EMOTION:empatia] Hola", .empathy),
            ("[EMOTION:picardía] Hola", .mischief),
            ("[EMOTION:picardia] Hola", .mischief),
            ("[EMOTION:humor] Hola", .mischief),
            ("[EMOTION:sorpresa] Hola", .surprise),
            ("[EMOTION:curiosidad] Hola", .curious),
            ("[EMOTION:curioso] Hola", .curious),
            ("[EMOTION:descanso] Hola", .sleepy),
            ("[EMOTION:sueño] Hola", .sleepy),
            ("[EMOTION:sueno] Hola", .sleepy),
            ("[EMOTION:molesto] Hola", .annoyed),
            ("[EMOTION:fastidio] Hola", .annoyed),
        ]

        for (input, expected) in cases {
            let parsed = CharacterEngine.parseResponse(input)
            #expect(parsed.emotion == expected)
            #expect(parsed.cleanText == "Hola")
        }
    }

    @Test("parseResponse strips tags at start, middle, and end cleanly")
    func parseTagPlacement() {
        let start = CharacterEngine.parseResponse("[EMOTION:curious] Observemos esto.")
        #expect(start == CharacterEngine.ParsedResponse(cleanText: "Observemos esto.", emotion: .curious))

        let middle = CharacterEngine.parseResponse("Primero [EMOTION:concentration] pensemos.")
        #expect(middle == CharacterEngine.ParsedResponse(cleanText: "Primero pensemos.", emotion: .concentration))

        let end = CharacterEngine.parseResponse("Buen punto [EMOTION:mischief]")
        #expect(end == CharacterEngine.ParsedResponse(cleanText: "Buen punto", emotion: .mischief))
    }

    @Test("parseResponse uses the last valid emotion tag when multiple tags appear")
    func parseMultipleTagsLastValidWins() {
        let parsed = CharacterEngine.parseResponse("Inicio [EMOTION:curious] medio [EMOTION:mischief] fin.")
        #expect(parsed.emotion == .mischief)
        #expect(parsed.cleanText == "Inicio medio fin.")

        let fallbackToEarlierValid = CharacterEngine.parseResponse("[EMOTION:sleepy] Texto [EMOTION:inexistente]")
        #expect(fallbackToEarlierValid.emotion == .sleepy)
        #expect(fallbackToEarlierValid.cleanText == "Texto")
    }

    @Test("parseResponse strips unknown valid-syntax tags and falls back to text heuristics")
    func parseUnknownTagFallsBackToHeuristics() {
        let parsed = CharacterEngine.parseResponse("[EMOTION:unknown_mood] Qué increíble!")
        #expect(parsed.cleanText == "Qué increíble!")
        #expect(parsed.emotion == .enthusiasm)
    }

    @Test("parseResponse handles tag-only input and preserves invalid tag syntax")
    func parseTagOnlyAndInvalidSyntax() {
        let tagOnly = CharacterEngine.parseResponse("   [EMOTION:concentration]   ")
        #expect(tagOnly == CharacterEngine.ParsedResponse(cleanText: "", emotion: .concentration))

        let emptyTag = CharacterEngine.parseResponse("[EMOTION:] Texto")
        #expect(emptyTag.cleanText == "[EMOTION:] Texto")
        #expect(emptyTag.emotion == .idle)

        let spacedTag = CharacterEngine.parseResponse("[EMOTION:curious 1] Texto")
        #expect(spacedTag.cleanText == "[EMOTION:curious 1] Texto")
        #expect(spacedTag.emotion == .idle)
    }

    @Test("stripEmotionTags handles empty, whitespace-only, and multiple spaces")
    func stripEmotionTagsBehavior() {
        #expect(CharacterEngine.stripEmotionTags(from: "") == "")
        #expect(CharacterEngine.stripEmotionTags(from: "  \n\t  ") == "")
        #expect(CharacterEngine.stripEmotionTags(from: "Hola   [EMOTION:idle]   mundo\n") == "Hola mundo")
    }

    @Test("stripStreamingTags hides complete tags and every progressive trailing partial prefix")
    func stripStreamingTagsProgressivePrefixes() {
        let fullMarker = "[EMOTION:curious"
        for length in 1...fullMarker.count {
            let prefix = String(fullMarker.prefix(length))
            let input = "Pensando contigo \(prefix)"
            #expect(CharacterEngine.stripStreamingTags(from: input) == "Pensando contigo")
        }

        #expect(CharacterEngine.stripStreamingTags(from: "[EMOT") == "")
        #expect(CharacterEngine.stripStreamingTags(from: "Hola [EMOTION:idle] mundo [EM") == "Hola mundo")
    }

    @Test("stripStreamingTags preserves non-emotion brackets while stripping trailing partial emotion tags")
    func stripStreamingTagsNonEmotionBrackets() {
        #expect(CharacterEngine.stripStreamingTags(from: "Array [1, 2") == "Array [1, 2")
        #expect(CharacterEngine.stripStreamingTags(from: "See [note") == "See [note")
        #expect(CharacterEngine.stripStreamingTags(from: "Ver [1] luego [EMOT") == "Ver [1] luego")
    }

    @Test("detectEmotion recognizes all 8 keyword categories")
    func detectEmotionCategories() {
        let samples: [(String, OSKOEmotion)] = [
            ("Lo siento, ha ocurrido un fallo.", .empathy),
            ("Esto es imposible de ignorar.", .annoyed),
            ("Estoy muy agotado esta madrugada.", .sleepy),
            ("Qué inesperado giro.", .surprise),
            ("Jaja, qué buena broma.", .mischief),
            ("Qué idea tan fascinante.", .enthusiasm),
            ("Analicemos el problema paso a paso.", .concentration),
            ("Me pregunto cómo funciona por dentro.", .curious),
        ]

        for (text, expected) in samples {
            #expect(CharacterEngine.detectEmotion(from: text) == expected)
        }
    }

    @Test("detectEmotion respects keyword priority order and keyword-before-punctuation precedence")
    func detectEmotionPriorityAndBoundaries() {
        #expect(CharacterEngine.detectEmotion(from: "Lo siento, qué sorpresa!") == .empathy)
        #expect(CharacterEngine.detectEmotion(from: "Es imposible pero genial!") == .annoyed)
        #expect(CharacterEngine.detectEmotion(from: "Esto empieza a ponerse interesante") == .enthusiasm)
        #expect(CharacterEngine.detectEmotion(from: "Por qué?") == .curious)
        #expect(CharacterEngine.detectEmotion(from: "Genial?") == .enthusiasm)

        // Word-boundary enforcement: partial subwords must not trigger keyword rules
        #expect(CharacterEngine.detectEmotion(from: "Detecté errores menores.") == .idle)
        #expect(CharacterEngine.detectEmotion(from: "jajajaja") == .idle)
    }

    @Test("detectEmotion applies punctuation fallbacks and neutral idle default")
    func detectEmotionPunctuationFallbacks() {
        #expect(CharacterEngine.detectEmotion(from: "Qué pasó?!") == .surprise)
        #expect(CharacterEngine.detectEmotion(from: "Cómo!?") == .surprise)
        #expect(CharacterEngine.detectEmotion(from: "Todo bien?") == .curious)
        #expect(CharacterEngine.detectEmotion(from: "Vamos!") == .enthusiasm)
        #expect(CharacterEngine.detectEmotion(from: "Texto completamente neutral.") == .idle)
        #expect(CharacterEngine.detectEmotion(from: "") == .idle)
    }

    @Test("OSKOVocalState maps all 9 OSKOEmotion cases deterministically")
    func vocalStateMapping() {
        #expect(OSKOVocalState.allCases.count == 4)
        #expect(Set(OSKOVocalState.allCases) == [.organic, .spark, .deep, .playful])

        #expect(OSKOEmotion.idle.vocalState == .organic)
        #expect(OSKOEmotion.empathy.vocalState == .organic)
        #expect(OSKOEmotion.sleepy.vocalState == .organic)

        #expect(OSKOEmotion.enthusiasm.vocalState == .spark)
        #expect(OSKOEmotion.curious.vocalState == .spark)
        #expect(OSKOEmotion.surprise.vocalState == .spark)

        #expect(OSKOEmotion.concentration.vocalState == .deep)
        #expect(OSKOEmotion.annoyed.vocalState == .deep)

        #expect(OSKOEmotion.mischief.vocalState == .playful)

        for emotion in OSKOEmotion.allCases {
            #expect(CharacterEngine.vocalState(for: emotion) == emotion.vocalState)
            let parsed = CharacterEngine.parseResponse("[EMOTION:\(emotion.rawValue)] Prueba")
            #expect(parsed.vocalState == emotion.vocalState)
        }
    }

    @Test("parseResponse maps deep_interest aliases and strips hyphenated/underscored unknown tags")
    func parseDeepInterestAliasesAndComplexUnknownTags() {
        let deepCases = [
            "[EMOTION:deep_interest] Observando",
            "[EMOTION:deep-interest] Observando",
            "[EMOTION:deepInterest] Observando",
            "[EMOTION:interes_profundo] Observando",
            "[EMOTION:interés-profundo] Observando",
        ]
        for input in deepCases {
            let parsed = CharacterEngine.parseResponse(input)
            #expect(parsed.emotion == .concentration)
            #expect(parsed.vocalState == .deep)
            #expect(parsed.cleanText == "Observando")
        }

        let unknownComplex = CharacterEngine.parseResponse("[EMOTION:deep-state_1] Texto limpio.")
        #expect(unknownComplex.cleanText == "Texto limpio.")
        #expect(unknownComplex.emotion == .idle)
    }

    @Test("parseResponse rejects emotion tags containing newlines")
    func parseRejectsNewlineInsideTag() {
        let withNewline = "[EMOTION:curious\n] Texto"
        let parsed = CharacterEngine.parseResponse(withNewline)
        #expect(parsed.cleanText == "[EMOTION:curious\n] Texto")
        #expect(parsed.emotion == .idle)

        let beforeNameNewline = "[EMOTION:\ncurious] Texto"
        let parsedBefore = CharacterEngine.parseResponse(beforeNameNewline)
        #expect(parsedBefore.cleanText == "[EMOTION:\ncurious] Texto")
    }

    @Test("stripStreamingTags handles nested brackets inside unclosed emotion tags")
    func stripStreamingTagsNestedUnclosedBracket() {
        #expect(CharacterEngine.stripStreamingTags(from: "Hola [EMOTION:cur [note") == "Hola")
        #expect(CharacterEngine.stripStreamingTags(from: "Hola [emotion:curious [1, 2") == "Hola")
        #expect(CharacterEngine.stripStreamingTags(from: "Lista [1] y [2") == "Lista [1] y [2")
    }

    @Test("detectEmotion folds Spanish diacritics cleanly")
    func detectEmotionDiacriticFolding() {
        #expect(CharacterEngine.detectEmotion(from: "Animo!") == .empathy)
        #expect(CharacterEngine.detectEmotion(from: "Perdon, me equivoque.") == .empathy)
        #expect(CharacterEngine.detectEmotion(from: "Que inesperado giro.") == .surprise)
        #expect(CharacterEngine.detectEmotion(from: "Veo una contradiccion aqui.") == .concentration)
        #expect(CharacterEngine.detectEmotion(from: "Un poco de picardia.") == .mischief)
        #expect(CharacterEngine.detectEmotion(from: "Esto es increible.") == .enthusiasm)
    }

    @Test("detectEmotion supports bilingual English heuristics without ambiguous word false positives")
    func detectEmotionEnglishHeuristics() {
        let samples: [(String, OSKOEmotion)] = [
            ("I am sorry, that looks overwhelming.", .empathy),
            ("That is frustrating and impossible.", .annoyed),
            ("I feel exhausted late night.", .sleepy),
            ("Whoa, that is surprising.", .surprise),
            ("Haha, just kidding with you.", .mischief),
            ("That is an amazing and brilliant idea.", .enthusiasm),
            ("Hold on, let's think step by step.", .concentration),
            ("I wonder what if we test that perspective.", .curious),
            ("Take the rest of the files.", .idle),
            ("That is enough context for the build.", .idle),
        ]

        for (text, expected) in samples {
            #expect(CharacterEngine.detectEmotion(from: text) == expected)
        }
    }
}
