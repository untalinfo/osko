//
//  OSKOMemoryManagerTests.swift
//  OSKOTests
//

import Foundation
import Testing
@testable import OSKO

@Suite("OSKOMemoryManager")
struct OSKOMemoryManagerTests {
    private func makeIsolatedStorageURL() -> (directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSKOMemoryManagerTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("osko_memory.json")
        return (directory, fileURL)
    }

    @Test("Missing store returns empty string")
    func missingStoreReturnsEmpty() async {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = OSKOMemoryManager(storageURL: fileURL)
        let result = await manager.retrieveRelevantMemories(for: "cualquier consulta")
        #expect(result == "")
    }

    @Test("Saved observation persists to disk and is retrieved by a fresh manager instance")
    func persistenceAcrossInstances() async {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = OSKOMemoryManager(storageURL: fileURL)
        await writer.saveObservation(
            content: "El usuario vive en Madrid y programa en Swift",
            tags: ["ubicacion", "lenguaje"]
        )

        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let reader = OSKOMemoryManager(storageURL: fileURL)
        let retrieved = await reader.retrieveRelevantMemories(for: "donde programa en Swift")
        #expect(retrieved == "MEMORIAS RECUPERADAS:\n- El usuario vive en Madrid y programa en Swift")
    }

    @Test("Empty and whitespace-only observations are ignored without creating storage file")
    func ignoresEmptyObservations() async {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(content: "")
        await manager.saveObservation(content: "   \n\t  ")

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Deduplicates observations ignoring case, diacritics, extra whitespace, and trailing punctuation")
    func normalizedDeduplication() async throws {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(content: "  Me gusta el café!! ")
        await manager.saveObservation(content: "me   gusta el cafe?")
        await manager.saveObservation(content: "\"ME GUSTA EL CAFÉ.\"")

        let data = try Data(contentsOf: fileURL)
        let stored = try JSONDecoder().decode([OSKOMemoryManager.Observation].self, from: data)
        #expect(stored.count == 1)
        #expect(stored.first?.content == "Me gusta el café!!")
    }

    @Test("Retrieves diacritic-insensitively and via tag matches")
    func diacriticAndTagRetrieval() async {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(
            content: "Le interesa la arquitectura hexagonal",
            tags: ["diseño", "backend"]
        )

        let byTag = await manager.retrieveRelevantMemories(for: "hablemos de diseno")
        #expect(byTag.contains("Le interesa la arquitectura hexagonal"))
    }

    @Test("Ignores short tokens (<= 2 chars) and returns empty for unrelated queries")
    func shortTokenAndUnrelatedFiltering() async {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(content: "El usuario usa Vim diariamente")

        let shortTokensOnly = await manager.retrieveRelevantMemories(for: "el de en")
        #expect(shortTokensOnly == "")

        let unrelated = await manager.retrieveRelevantMemories(for: "kubernetes")
        #expect(unrelated == "")

        let matched = await manager.retrieveRelevantMemories(for: "vim")
        #expect(matched.contains("El usuario usa Vim diariamente"))
    }

    @Test("Identity queries boost identity-related memories even without literal token overlap")
    func identityQueryBoosting() async {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(content: "Mi nombre es Oscar y trabajo con macOS")
        await manager.saveObservation(content: "Prefiere café sin azúcar")

        let whoAmI = await manager.retrieveRelevantMemories(for: "quién soy")
        #expect(whoAmI.contains("Mi nombre es Oscar y trabajo con macOS"))

        let myName = await manager.retrieveRelevantMemories(for: "cómo me llamo")
        #expect(myName.contains("Mi nombre es Oscar y trabajo con macOS"))

        let aboutMe = await manager.retrieveRelevantMemories(for: "sabes de mi")
        #expect(aboutMe.contains("Mi nombre es Oscar y trabajo con macOS"))
    }

    @Test("Caps retrieval at 5 observations sorted by score descending then timestamp descending")
    func topFiveCapAndOrdering() async throws {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let seeded: [OSKOMemoryManager.Observation] = [
            .init(id: UUID(), content: "alpha uno", timestamp: Date(timeIntervalSince1970: 100), tags: []),
            .init(id: UUID(), content: "alpha dos", timestamp: Date(timeIntervalSince1970: 200), tags: []),
            .init(id: UUID(), content: "alpha tres", timestamp: Date(timeIntervalSince1970: 300), tags: []),
            .init(id: UUID(), content: "alpha cuatro", timestamp: Date(timeIntervalSince1970: 400), tags: []),
            .init(id: UUID(), content: "alpha cinco", timestamp: Date(timeIntervalSince1970: 500), tags: []),
            .init(id: UUID(), content: "alpha seis", timestamp: Date(timeIntervalSince1970: 600), tags: []),
            .init(id: UUID(), content: "alpha beta doble", timestamp: Date(timeIntervalSince1970: 50), tags: []),
        ]

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(seeded).write(to: fileURL, options: .atomic)

        let manager = OSKOMemoryManager(storageURL: fileURL)
        let result = await manager.retrieveRelevantMemories(for: "alpha beta")
        let expected = [
            "MEMORIAS RECUPERADAS:",
            "- alpha beta doble",
            "- alpha seis",
            "- alpha cinco",
            "- alpha cuatro",
            "- alpha tres",
        ].joined(separator: "\n")
        #expect(result == expected)
    }

    @Test("Evicts oldest observations FIFO when exceeding 100 entries")
    func fifoEvictionAtOneHundred() async throws {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let seeded = (0..<100).map { index in
            OSKOMemoryManager.Observation(
                id: UUID(),
                content: String(format: "Observation %03d", index),
                timestamp: Date(timeIntervalSince1970: Double(index)),
                tags: []
            )
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(seeded).write(to: fileURL, options: .atomic)

        let manager = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(content: "Observation 100")

        let data = try Data(contentsOf: fileURL)
        let stored = try JSONDecoder().decode([OSKOMemoryManager.Observation].self, from: data)
        let contents = Set(stored.map(\.content))

        #expect(stored.count == 100)
        #expect(!contents.contains("Observation 000"))
        #expect(contents.contains("Observation 001"))
        #expect(contents.contains("Observation 100"))
    }

    @Test("Recovers from corrupt JSON by backing up to osko_memory.corrupt.json and accepting new saves")
    func corruptJSONRecovery() async throws {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let staleBackupURL = parentDir.appendingPathComponent("osko_memory.corrupt.json")
        try Data("stale backup".utf8).write(to: staleBackupURL)

        let corruptPayload = Data("{not valid json".utf8)
        try corruptPayload.write(to: fileURL)

        let manager = OSKOMemoryManager(storageURL: fileURL)
        let emptyResult = await manager.retrieveRelevantMemories(for: "memoria")
        #expect(emptyResult == "")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(FileManager.default.fileExists(atPath: staleBackupURL.path))
        #expect(try Data(contentsOf: staleBackupURL) == corruptPayload)

        await manager.saveObservation(content: "Memoria recuperada correctamente")

        let freshReader = OSKOMemoryManager(storageURL: fileURL)
        let recovered = await freshReader.retrieveRelevantMemories(for: "recuperada")
        #expect(recovered.contains("Memoria recuperada correctamente"))
    }

    @Test("Whole-token matching prevents substring false positives for tokens and identity terms")
    func wholeTokenPreventsSubstringFalsePositives() async {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(content: "Tuve una llamada importante sobre leche de soya en el vivero")

        let llamaQuery = await manager.retrieveRelevantMemories(for: "llama")
        #expect(llamaQuery == "")

        let soyQuery = await manager.retrieveRelevantMemories(for: "soy")
        #expect(soyQuery == "")

        let viveQuery = await manager.retrieveRelevantMemories(for: "vive")
        #expect(viveQuery == "")

        let identityQuery = await manager.retrieveRelevantMemories(for: "quien soy")
        #expect(identityQuery == "")
    }

    @Test("Multi-space and punctuated identity phrases match accurately without false positives")
    func identityPhraseSpacingAndBoundaries() async {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(content: "El usuario se llama Oscar y trabaja en macOS")

        let multiSpaceSobreMi = await manager.retrieveRelevantMemories(for: "cuéntame sobre   mi")
        #expect(multiSpaceSobreMi.contains("Oscar"))

        let punctuatedQuienSoy = await manager.retrieveRelevantMemories(for: "¿Quién   soy?")
        #expect(punctuatedQuienSoy.contains("Oscar"))

        let multiSpaceComoMeLlamo = await manager.retrieveRelevantMemories(for: "¿Cómo  me  llamo?")
        #expect(multiSpaceComoMeLlamo.contains("Oscar"))

        let metricsFalsePositive = await manager.retrieveRelevantMemories(for: "about metrics")
        #expect(metricsFalsePositive == "")

        let aboutTopicFalsePositive = await manager.retrieveRelevantMemories(for: "tell me about Swift")
        #expect(aboutTopicFalsePositive == "")
    }

    @Test("Deduplication strips inverted Spanish punctuation and typographic quotes")
    func invertedPunctuationDeduplication() async throws {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(content: "¡Me gusta el café!")
        await manager.saveObservation(content: "¿Me gusta el café?")
        await manager.saveObservation(content: "«Me gusta el cafe»")

        let data = try Data(contentsOf: fileURL)
        let stored = try JSONDecoder().decode([OSKOMemoryManager.Observation].self, from: data)
        #expect(stored.count == 1)
    }

    @Test("Retrieves direct content diacritics and punctuated tokens without tags")
    func directContentDiacriticsAndPunctuationTokens() async {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(content: "Oscar's diseño en Swift/MLX es minimalista")

        let diacriticQuery = await manager.retrieveRelevantMemories(for: "diseno")
        #expect(diacriticQuery.contains("diseño"))

        let splitTokenQuery = await manager.retrieveRelevantMemories(for: "mlx")
        #expect(splitTokenQuery.contains("Swift/MLX"))
    }

    @Test("Supports bilingual English identity queries and OSKOMemoryManaging protocol")
    func bilingualEnglishIdentityRetrieval() async {
        let (dir, fileURL) = makeIsolatedStorageURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager: any OSKOMemoryManaging = OSKOMemoryManager(storageURL: fileURL)
        await manager.saveObservation(content: "User's name is Oscar and he lives in Colombia")
        await manager.saveObservation(content: "El usuario prefiere arquitectura limpia")

        let whoAmI = await manager.retrieveRelevantMemories(for: "who am i")
        #expect(whoAmI.contains("User's name is Oscar"))

        let whatIsMyName = await manager.retrieveRelevantMemories(for: "What's my name?")
        #expect(whatIsMyName.contains("User's name is Oscar"))

        let aboutMe = await manager.retrieveRelevantMemories(for: "what do you know about me?")
        #expect(aboutMe.contains("User's name is Oscar"))
        #expect(aboutMe.contains("arquitectura limpia"))
    }
}
