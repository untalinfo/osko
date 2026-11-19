//
//  OSKOMemoryManager.swift
//  OSKO
//
//  Created by Oscar Info Giraldo on 6/11/26.
//

import Foundation
import os

protocol OSKOMemoryManaging: Actor {
    func warmUp()
    func saveObservation(content: String, tags: [String])
    func retrieveRelevantMemories(for prompt: String) -> String
}

extension OSKOMemoryManaging {
    func warmUp() {}

    func saveObservation(content: String) {
        saveObservation(content: content, tags: [])
    }
}

/// OSKOMemoryManager implements a persistent observation store for OSKO.
/// Isolated to its own actor so JSON disk I/O never blocks the main actor.
actor OSKOMemoryManager: OSKOMemoryManaging {
    nonisolated struct Observation: Codable, Sendable {
        let id: UUID
        let content: String
        let timestamp: Date
        let tags: [String]

        init(id: UUID = UUID(), content: String, timestamp: Date = Date(), tags: [String] = []) {
            self.id = id
            self.content = content
            self.timestamp = timestamp
            self.tags = tags
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case content
            case timestamp
            case tags
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
            self.content = try container.decode(String.self, forKey: .content)
            self.tags = (try? container.decode([String].self, forKey: .tags)) ?? []

            if let date = try? container.decode(Date.self, forKey: .timestamp) {
                self.timestamp = date
            } else if let isoString = try? container.decode(String.self, forKey: .timestamp),
                      let parsedDate = ISO8601DateFormatter().date(from: isoString) {
                self.timestamp = parsedDate
            } else {
                self.timestamp = Date()
            }
        }
    }

    nonisolated private static let maxObservations = 100
    nonisolated private static let identityQueryTerms: Set<String> = [
        // Spanish
        "nombre", "llamo", "llama", "quien", "soy", "identidad",
        "oscar", "usuario", "recuerdas", "gusto", "gustos",
        "preferencia", "preferencias", "prefiero", "vivo", "vive",
        "trabajo", "trabaja",
        // English
        "user", "name", "who", "identity", "remember", "preference",
        "preferences", "prefer", "like", "likes", "live", "lives",
        "work", "works", "myself", "favorite", "favourite", "called",
    ]
    nonisolated private static let identityPhrases = [
        // Spanish
        "sobre mi", "sabes de mi", "quien soy", "como me llamo",
        "que recuerdas de mi", "acerca de mi",
        // English
        "about me", "know about me", "who am i", "what is my name",
        "whats my name", "what s my name", "do you remember me",
        "remember about me", "tell me about myself",
    ]
    nonisolated private static let identityContentTerms: Set<String> = [
        // Spanish
        "nombre", "llama", "soy", "identidad", "usuario", "oscar",
        "preferencia", "prefiere", "gusta", "vive", "trabaja",
        // English
        "name", "called", "identity", "user", "prefer", "prefers",
        "preference", "preferences", "like", "likes", "love", "loves",
        "live", "lives", "work", "works", "favorite", "favourite",
    ]

    private let logger = Logger(subsystem: "com.infodev.OSKO", category: "Memory")
    private let storageURL: URL
    private var cachedMemories: [Observation]?

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let baseDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            let appSupportDir = baseDir.appendingPathComponent("OSKO", isDirectory: true)
            self.storageURL = appSupportDir.appendingPathComponent("osko_memory.json")
        }
    }

    /// Preloads observations from disk and triggers corrupt-file backup recovery immediately if needed.
    func warmUp() {
        _ = loadMemories()
    }

    /// Saves a new observation if it is non-empty and not a duplicate, capping total stored entries.
    func saveObservation(content: String, tags: [String] = []) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        var memories = loadMemories()
        let normalizedCandidate = Self.normalizeForComparison(trimmedContent)

        if memories.contains(where: { Self.normalizeForComparison($0.content) == normalizedCandidate }) {
            logger.debug("Skipping duplicate memory observation")
            return
        }

        let observation = Observation(
            id: UUID(),
            content: trimmedContent,
            timestamp: Date(),
            tags: tags
        )
        memories.append(observation)

        if memories.count > Self.maxObservations {
            memories.sort { $0.timestamp < $1.timestamp }
            memories = Array(memories.suffix(Self.maxObservations))
        }

        cachedMemories = memories
        saveToDisk(memories)
    }

    /// Retrieves up to 5 relevant observations for `prompt`.
    func retrieveRelevantMemories(for prompt: String) -> String {
        let memories = loadMemories()
        guard !memories.isEmpty else { return "" }

        let normalizedQuery = Self.normalizeFolded(prompt)
        let collapsedQuery = Self.collapseWords(normalizedQuery)
        let queryTokens = Self.tokenize(normalizedQuery)
        let isIdentityQuery = Self.identityPhrases.contains(where: {
            Self.containsWholePhrase(collapsedQuery, phrase: $0)
        }) || queryTokens.contains(where: { Self.identityQueryTerms.contains($0) })

        var scoredObservations: [(observation: Observation, score: Int)] = []

        for obs in memories {
            let normalizedContent = Self.normalizeFolded(obs.content)
            let normalizedTags = obs.tags.map { Self.normalizeFolded($0) }
            let contentTokens = Set(Self.tokenize(normalizedContent))
            let tagTokens = Set(normalizedTags.flatMap { Self.tokenize($0) })
            var score = 0

            for token in queryTokens {
                if contentTokens.contains(token) || tagTokens.contains(token) {
                    score += 5
                }
            }

            if isIdentityQuery && Self.identityContentTerms.contains(where: {
                contentTokens.contains($0) || tagTokens.contains($0)
            }) {
                score += 5
            }

            if score > 0 {
                scoredObservations.append((obs, score))
            }
        }

        let topMemories = scoredObservations
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.observation.timestamp > $1.observation.timestamp
            }
            .prefix(5)
            .map(\.observation.content)

        if topMemories.isEmpty {
            logger.debug("No relevant memories found for query")
            return ""
        }

        logger.debug("Retrieved \(topMemories.count, privacy: .public) relevant memories")
        return "MEMORIAS RECUPERADAS:\n- " + topMemories.joined(separator: "\n- ")
    }

    private func loadMemories() -> [Observation] {
        if let cachedMemories {
            return cachedMemories
        }

        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            cachedMemories = []
            return []
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([Observation].self, from: data)
            cachedMemories = decoded
            return decoded
        } catch {
            logger.error("Failed to decode memory store: \(error.localizedDescription, privacy: .public)")
            let backupURL = storageURL.deletingLastPathComponent()
                .appendingPathComponent("osko_memory.corrupt.json")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: storageURL, to: backupURL)
            cachedMemories = []
            return []
        }
    }

    private func saveToDisk(_ memories: [Observation]) {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(memories)
            try data.write(to: storageURL, options: .atomic)
            logger.debug("Saved \(memories.count, privacy: .public) memories atomically")
        } catch {
            logger.error("Failed to save memory store: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func normalizeFolded(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    nonisolated private static func normalizeForComparison(_ text: String) -> String {
        normalizeFolded(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'¡¿“”‘’«»"))
    }

    nonisolated private static func collapseWords(_ normalizedText: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return normalizedText
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func containsWholePhrase(_ collapsedQuery: String, phrase: String) -> Bool {
        guard !collapsedQuery.isEmpty else { return false }
        return " \(collapsedQuery) ".contains(" \(phrase) ")
    }

    nonisolated private static func tokenize(_ normalizedText: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var seen = Set<String>()
        var tokens: [String] = []
        for token in normalizedText.components(separatedBy: separators) {
            guard token.count > 2, seen.insert(token).inserted else { continue }
            tokens.append(token)
        }
        return tokens
    }
}
