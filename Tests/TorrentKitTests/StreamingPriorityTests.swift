import Foundation
import Testing

@testable import TorrentKit

/// First-and-last-piece priority, which is what makes playback-before-complete
/// actually work. Sequential download alone is not enough: most media
/// containers keep their index at the end of the file.
@Suite("First and last piece priority")
struct StreamingPriorityTests {

    /// A torrent large enough to have many pieces, so prioritising the ends is
    /// distinguishable from prioritising everything.
    static func makeSession() async throws -> (
        session: TorrentSession, hash: InfoHash, directories: [URL]
    ) {
        let content = try LoopbackTransferTests.makeDirectory("fl-content")
        let work = try LoopbackTransferTests.makeDirectory("fl-work")
        let media = content.appendingPathComponent("movie.mp4")
        // 1 MiB across 64 pieces of 16 KiB.
        try LoopbackTransferTests.makePayload(bytes: 1_048_576).write(to: media)

        let torrentURL = work.appendingPathComponent("movie.torrent")
        try TorrentEngine.createTorrentFile(
            describing: media, writingTo: torrentURL, pieceLength: 16_384)

        let session = try TorrentSession(configuration: LoopbackTransferTests.isolated)
        let hash = try await session.addTorrentFile(at: torrentURL, savePath: content)
        _ = await TorrentSessionTests.firstEvent(from: session) { event in
            if case .torrentAdded = event { return true }
            return false
        }
        return (session, hash, [content, work])
    }

    @Test func isOffByDefault() async throws {
        let (session, hash, directories) = try await Self.makeSession()
        defer {
            Task { await session.shutdown() }
            for url in directories { try? FileManager.default.removeItem(at: url) }
        }
        #expect(await session.hasFirstLastPiecePriority(hash) == false)
    }

    @Test func enablingItIsReportedBack() async throws {
        let (session, hash, directories) = try await Self.makeSession()
        defer {
            Task { await session.shutdown() }
            for url in directories { try? FileManager.default.removeItem(at: url) }
        }

        try await session.setFirstLastPiecePriority(true, for: hash)

        // Piece priorities are applied on libtorrent's thread, so poll rather
        // than reading straight back.
        var enabled = false
        for _ in 0..<50 {
            enabled = await session.hasFirstLastPiecePriority(hash)
            if enabled { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(enabled, "the ends should be prioritised")
    }

    @Test func turningItBackOffIsReportedBack() async throws {
        let (session, hash, directories) = try await Self.makeSession()
        defer {
            Task { await session.shutdown() }
            for url in directories { try? FileManager.default.removeItem(at: url) }
        }

        try await session.setFirstLastPiecePriority(true, for: hash)
        for _ in 0..<50 where !(await session.hasFirstLastPiecePriority(hash)) {
            try await Task.sleep(for: .milliseconds(100))
        }

        try await session.setFirstLastPiecePriority(false, for: hash)
        var stillEnabled = true
        for _ in 0..<50 {
            stillEnabled = await session.hasFirstLastPiecePriority(hash)
            if !stillEnabled { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!stillEnabled, "the ends should be back to normal priority")
    }

    /// Sequential and end-priority are independent switches; the streaming
    /// preset is both together.
    @Test func combinesWithSequentialDownload() async throws {
        let (session, hash, directories) = try await Self.makeSession()
        defer {
            Task { await session.shutdown() }
            for url in directories { try? FileManager.default.removeItem(at: url) }
        }

        try await session.setSequentialDownload(true, for: hash)
        try await session.setFirstLastPiecePriority(true, for: hash)

        await session.startPollingStatus(every: .milliseconds(200))
        var sequential = false
        for _ in 0..<30 {
            let event = await TorrentSessionTests.firstEvent(
                from: session, timeout: .seconds(2)
            ) { event in
                if case .statusUpdated = event { return true }
                return false
            }
            if case .statusUpdated(let status)? = event, status.isSequential {
                sequential = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(sequential, "sequential download should be reported in the status")
        #expect(await session.hasFirstLastPiecePriority(hash))
    }

    @Test func unknownTorrentReportsFalseRatherThanThrowing() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }
        #expect(await session.hasFirstLastPiecePriority(
            InfoHash(String(repeating: "d", count: 40))) == false)
    }
}
