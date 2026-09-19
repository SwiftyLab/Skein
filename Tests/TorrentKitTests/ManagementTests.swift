import Foundation
import Testing

@testable import TorrentKit

/// Per-torrent management: files, priorities, limits, queue, and details.
@Suite("Torrent management")
struct ManagementTests {

    /// A session with one multi-file torrent already added and checked.
    static func makeSeededSession() async throws -> (
        session: TorrentSession, hash: InfoHash, directories: [URL]
    ) {
        let content = try LoopbackTransferTests.makeDirectory("content")
        let work = try LoopbackTransferTests.makeDirectory("work")
        let payloadDirectory = content.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)

        // Three files, so priorities and per-file progress are meaningful.
        for (name, size) in [("alpha.bin", 65_536), ("beta.bin", 131_072), ("gamma.bin", 32_768)] {
            try LoopbackTransferTests.makePayload(bytes: size)
                .write(to: payloadDirectory.appendingPathComponent(name))
        }

        let torrentURL = work.appendingPathComponent("bundle.torrent")
        try TorrentEngine.createTorrentFile(
            describing: payloadDirectory, writingTo: torrentURL, pieceLength: 16_384)

        let session = try TorrentSession(configuration: LoopbackTransferTests.isolated)
        let hash = try await session.addTorrentFile(at: torrentURL, savePath: content)

        // Files only become visible once libtorrent has parsed the metadata.
        _ = await TorrentSessionTests.firstEvent(from: session) { event in
            if case .torrentAdded = event { return true }
            return false
        }
        return (session, hash, [content, work])
    }

    @Test func listsFilesWithSizesAndPriorities() async throws {
        let (session, hash, directories) = try await Self.makeSeededSession()
        defer {
            Task { await session.shutdown() }
            for url in directories { try? FileManager.default.removeItem(at: url) }
        }

        let files = await session.files(of: hash)
        #expect(files.count == 3)
        #expect(files.map(\.name).sorted() == ["alpha.bin", "beta.bin", "gamma.bin"])
        #expect(files.allSatisfy { $0.priority == .normal })
        #expect(files.first { $0.name == "beta.bin" }?.size == 131_072)
    }

    @Test func settingFilePriorityTakesEffect() async throws {
        let (session, hash, directories) = try await Self.makeSeededSession()
        defer {
            Task { await session.shutdown() }
            for url in directories { try? FileManager.default.removeItem(at: url) }
        }

        let target = try #require(await session.files(of: hash).first { $0.name == "gamma.bin" })
        try await session.setPriority(.skip, forFileAt: target.index, in: hash)

        // libtorrent applies priority changes on its own thread, so the new
        // value is not visible to the very next read. Poll rather than assume.
        var updated: TorrentFile?
        for _ in 0..<50 {
            updated = await session.files(of: hash).first { $0.index == target.index }
            if updated?.priority == .skip { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(updated?.priority == .skip)
    }

    @Test func acceptsLimitsSequentialAndQueueChanges() async throws {
        let (session, hash, directories) = try await Self.makeSeededSession()
        defer {
            Task { await session.shutdown() }
            for url in directories { try? FileManager.default.removeItem(at: url) }
        }

        // These have no directly observable status field, so the assertion is
        // that libtorrent accepts them rather than throwing.
        try await session.setLimits(for: hash, download: 51_200, upload: 25_600)
        try await session.setSequentialDownload(true, for: hash)
        try await session.setQueuePosition(0, for: hash)
        try await session.reannounce(hash)
    }

    @Test func reportsPieceAvailabilityForACompleteTorrent() async throws {
        let (session, hash, directories) = try await Self.makeSeededSession()
        defer {
            Task { await session.shutdown() }
            for url in directories { try? FileManager.default.removeItem(at: url) }
        }

        // The data is already on disk, so every piece should verify.
        var pieces: [Bool] = []
        for _ in 0..<40 {
            pieces = await session.pieceAvailability(of: hash)
            if !pieces.isEmpty, pieces.allSatisfy({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!pieces.isEmpty, "no piece map returned")
        #expect(pieces.allSatisfy { $0 }, "seeded torrent should have every piece")
    }

    @Test func listsTrackersAndPeersWithoutThrowing() async throws {
        let (session, hash, directories) = try await Self.makeSeededSession()
        defer {
            Task { await session.shutdown() }
            for url in directories { try? FileManager.default.removeItem(at: url) }
        }

        // The fixture is trackerless and isolated, so both are expected empty;
        // the point is that the query paths work and convert cleanly.
        #expect(await session.trackers(of: hash).isEmpty)
        #expect(await session.peers(of: hash).isEmpty)
    }

    @Test func detailQueriesOnUnknownTorrentReturnEmpty() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }
        let missing = InfoHash(String(repeating: "c", count: 40))

        // Must degrade to empty rather than crashing on a missing handle.
        #expect(await session.files(of: missing).isEmpty)
        #expect(await session.peers(of: missing).isEmpty)
        #expect(await session.trackers(of: missing).isEmpty)
        #expect(await session.pieceAvailability(of: missing).isEmpty)
    }
}
