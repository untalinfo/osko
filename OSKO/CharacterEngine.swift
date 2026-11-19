//
//  CharacterEngine.swift
//  OSKO
//
//  Created by Oscar Info Giraldo on 6/11/26.
//

import Foundation

/// Emotional states expressed visually by OSKO in accordance with the OSKO Character Bible.
enum OSKOEmotion: String, CaseIterable, Sendable {
    case idle
    case concentration
    case enthusiasm
    case empathy
    case mischief
    case surprise
    case curious
    case sleepy
    case annoyed

    var vocalState: OSKOVocalState {
        switch self {
        case .idle, .empathy, .sleepy:
            return .organic
        case .enthusiasm, .curious, .surprise:
            return .spark
        case .concentration, .annoyed:
            return .deep
        case .mischief:
            return .playful
        }
    }
}

/// Conceptual vocal states defined by the OSKO Character Bible (§6).
enum OSKOVocalState: String, CaseIterable, Sendable {
    case organic
    case spark
    case deep
    case playful
}

/// Parses model output to extract OSKO's emotional state and clean display text.
enum CharacterEngine {
    struct ParsedResponse: Equatable, Sendable {
        let cleanText: String
        let emotion: OSKOEmotion

        var vocalState: OSKOVocalState {
            emotion.vocalState
        }
    }

    static func vocalState(for emotion: OSKOEmotion) -> OSKOVocalState {
        emotion.vocalState
    }

    private static let emotionTagPattern = #"\[EMOTION:[ \t]*([a-zA-Z0-9áéíóúñÁÉÍÓÚÑ_-]+)[ \t]*\]"#
    private static let emotionTagRegex = try? NSRegularExpression(
        pattern: emotionTagPattern,
        options: [.caseInsensitive]
    )

    private static let emotionAliases: [String: OSKOEmotion] = [
        "idle": .idle,
        "reposo": .idle,
        "neutral": .idle,
        "calm": .idle,
        "concentration": .concentration,
        "concentracion": .concentration,
        "concentración": .concentration,
        "deep": .concentration,
        "deep_interest": .concentration,
        "deep-interest": .concentration,
        "deepinterest": .concentration,
        "interes_profundo": .concentration,
        "interes-profundo": .concentration,
        "interesprofundo": .concentration,
        "interés_profundo": .concentration,
        "interés-profundo": .concentration,
        "enthusiasm": .enthusiasm,
        "entusiasmo": .enthusiasm,
        "spark": .enthusiasm,
        "empathy": .empathy,
        "empatia": .empathy,
        "empatía": .empathy,
        "organic": .empathy,
        "mischief": .mischief,
        "picardia": .mischief,
        "picardía": .mischief,
        "humor": .mischief,
        "playful": .mischief,
        "surprise": .surprise,
        "sorpresa": .surprise,
        "curious": .curious,
        "curioso": .curious,
        "curiosidad": .curious,
        "sleepy": .sleepy,
        "descanso": .sleepy,
        "sueno": .sleepy,
        "sueño": .sleepy,
        "annoyed": .annoyed,
        "molesto": .annoyed,
        "fastidio": .annoyed,
    ]

    /// Parses a complete assistant response, stripping any `[EMOTION:<name>]` tags
    /// and falling back to keyword/punctuation heuristics when no valid tag is present.
    static func parseResponse(_ text: String) -> ParsedResponse {
        let taggedEmotion = extractStructuredEmotion(from: text)
        let cleanText = stripEmotionTags(from: text)
        let emotion = taggedEmotion ?? detectEmotion(from: cleanText)
        return ParsedResponse(cleanText: cleanText, emotion: emotion)
    }

    /// Strips completed `[EMOTION:...]` tags and hides any trailing partial tag while streaming
    /// (including partial prefixes like `[`, `[E`, `[EM`, ..., `[EMOTION:...` without a closing `]`).
    static func stripStreamingTags(from text: String) -> String {
        var sanitized = stripEmotionTags(from: text)
        if let markerRange = sanitized.range(of: "[emotion:", options: [.caseInsensitive, .backwards]) {
            let trailing = sanitized[markerRange.lowerBound...]
            if !trailing.contains("]") {
                return String(sanitized[..<markerRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let lastOpenBracket = sanitized.lastIndex(of: "[") {
            let trailing = sanitized[lastOpenBracket...]
            if !trailing.contains("]") {
                let lowerTrailing = trailing.lowercased()
                let marker = "[emotion:"
                if marker.hasPrefix(lowerTrailing) || lowerTrailing.hasPrefix(marker) {
                    sanitized = String(sanitized[..<lastOpenBracket])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return sanitized
    }

    /// Removes all `[EMOTION:...]` tags from `text` and normalizes surrounding whitespace.
    static func stripEmotionTags(from text: String) -> String {
        guard let regex = emotionTagRegex else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(text.startIndex..., in: text)
        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let emotionKeywordRegexes: [(emotion: OSKOEmotion, regex: NSRegularExpression)] = {
        let rules: [(OSKOEmotion, [String])] = [
            (.empathy, [
                "lo siento", "perdon", "disculpa", "triste", "abrumado",
                "animo", "comprendo", "lamento", "error", "no tienes que resolverlo todo",
                "sorry", "i understand", "overwhelmed", "feel bad", "apologize",
                "apologies", "it's okay", "take it easy", "you don't have to solve everything",
            ]),
            (.annoyed, [
                "no puedo", "imposible", "estoy harto", "frustrante", "molesto", "basta",
                "i can't", "impossible", "fed up", "frustrating", "annoying",
                "that's enough", "stop it",
            ]),
            (.sleepy, [
                "cansado", "sueno", "dormir", "descansar", "agotado", "madrugada",
                "tired", "sleepy", "exhausted", "need rest", "take a rest",
                "late night", "need sleep",
            ]),
            (.surprise, [
                "sorpresa", "sorprendente", "que inesperado", "no me lo esperaba", "guau", "wow", "en serio",
                "surprise", "surprising", "unexpected", "didn't expect", "whoa",
                "seriously", "no way",
            ]),
            (.mischief, [
                "jaja", "jeje", "ironia", "picaro", "picardia", "broma", "guino", "complicidad",
                "haha", "hehe", "irony", "ironic", "playful", "just kidding",
                "teasing", "wink", "mischief",
            ]),
            (.enthusiasm, [
                "genial", "increible", "fascinante", "excelente", "brillante",
                "ahora si", "empieza a ponerse interesante", "me encanta",
                "awesome", "amazing", "incredible", "fascinating", "excellent",
                "brilliant", "love it", "exciting",
            ]),
            (.concentration, [
                "espera", "analizando", "pensemos", "paso a paso", "veamos",
                "revisemos", "profundicemos", "detalle importante", "contradiccion",
                "hold on", "analyzing", "let's think", "step by step", "let's check",
                "let's look", "contradiction", "dig deeper",
            ]),
            (.curious, [
                "curioso", "curiosidad", "perspectiva", "que pasaria", "por que",
                "como funciona", "y si lo miramos", "me pregunto", "interesante",
                "curious", "curiosity", "perspective", "what if", "why does",
                "why is", "why would", "why not", "how does", "i wonder", "interesting",
            ]),
        ]

        return rules.compactMap { emotion, phrases in
            let escaped = phrases.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            guard let regex = try? NSRegularExpression(pattern: "\\b(?:\(escaped))\\b", options: [.caseInsensitive]) else {
                return nil
            }
            return (emotion, regex)
        }
    }()

    /// Determines emotion from text heuristics.
    /// Specific whole-word/phrase keywords are evaluated before generic `!` or `?` punctuation fallbacks.
    static func detectEmotion(from text: String) -> OSKOEmotion {
        let strippedForHeuristics = emotionTagRegex.map { regex in
            let fullRange = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: "")
        } ?? text
        // Also ignore any invalid/unrecognized `[EMOTION:...]` bracket block when evaluating keyword heuristics
        let withoutMalformedEmotionTags = strippedForHeuristics.replacingOccurrences(
            of: #"\[EMOTION:[^\]]*\]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let foldedText = withoutMalformedEmotionTags.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let range = NSRange(foldedText.startIndex..., in: foldedText)

        for rule in emotionKeywordRegexes {
            if rule.regex.firstMatch(in: foldedText, options: [], range: range) != nil {
                return rule.emotion
            }
        }

        // Generic punctuation fallbacks evaluated only after all specific keywords.
        if text.contains("?!") || text.contains("!?") {
            return .surprise
        }
        if text.contains("?") {
            return .curious
        }
        if text.contains("!") {
            return .enthusiasm
        }

        return .idle
    }

    private static func extractStructuredEmotion(from text: String) -> OSKOEmotion? {
        guard let regex = emotionTagRegex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let rawName = text[nameRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let mapped = emotionAliases[rawName] ?? OSKOEmotion(rawValue: rawName) {
                return mapped
            }
        }
        return nil
    }
}
