import Foundation
import Testing

@testable import TorrentKit

@Suite("Resume data persistence")
struct PersistenceTests {

    static func makeStoreDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func storeRoundTripsResumeData() async throws {
        let directory = try Self.makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TorrentStore(directory: directory)

        let hash = InfoHash(String(repeating: "a", count: 40))
        // Deliberately not valid UTF-8: resume data is binary, and this fails
        // if anything in the path routes it through a String.
        let payload = Data([0x00, 0xFF, 0xFE, 0x80, 0x01, 0x7F])
        try await store.save(payload, for: hash)

        let loaded = await store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.infoHash == hash)
        #expect(loaded.first?.data == payload)

        await store.remove(hash)
        #expect(await store.count == 0)
    }

    /// The end-to-end persistence path: add a torrent, save its resume data,
    /// stop the session, then restore into a fresh one.
    @Test func torrentSurvivesSessionRestart() async throws {
        let directory = try Self.makeStoreDirectory()
        let savePath = try TorrentSessionTests.makeScratchDirectory()
        let torrent = try TorrentSessionTests.makeTorrentFile()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: savePath)
            try? FileManager.default.removeItem(at: torrent)
        }
        let store = try TorrentStore(directory: directory)

        let original: InfoHash
        do {
            let session = try TorrentSession(configuration: .offline)
            original = try await session.addTorrentFile(at: torrent, savePath: savePath)

            // Resume data is only available once libtorrent has the torrent
            // registered, which the torrentAdded alert confirms.
            _ = await TorrentSessionTests.firstEvent(from: session) { event in
                if case .torrentAdded = event { return true }
                return false
            }

            let saved = await session.persistResumeData(to: store, timeout: .seconds(10))
            #expect(saved >= 1, "expected resume data for the added torrent")
            await session.shutdown()
        }

        #expect(await store.count == 1)

        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }
        let outcome = await session.restore(from: store)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.restored == [original])
    }

    @Test func restoringCorruptResumeDataDropsTheEntry() async throws {
        let directory = try Self.makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TorrentStore(directory: directory)

        let hash = InfoHash(String(repeating: "b", count: 40))
        try await store.save(Data("not bencoded resume data".utf8), for: hash)

        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }

        let outcome = await session.restore(from: store)
        #expect(outcome.restored.isEmpty)
        #expect(outcome.failures.count == 1)
        // Dropped rather than retried forever on every launch.
        #expect(await store.count == 0)
    }
}
