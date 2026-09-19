import Foundation
import Testing

@testable import TorrentKit

/// Renaming content and moving storage. Both touch real paths on disk, so these
/// assert the filesystem rather than just that the call returned.
@Suite("Rename and move")
struct RenameAndMoveTests {

    /// A single-file torrent, already complete so it is seeding immediately.
    static func makeSingleFile() async throws -> (
        session: TorrentSession, hash: InfoHash, save: URL, directories: [URL]
    ) {
        let content = try LoopbackTransferTests.makeDirectory("rn-content")
        let work = try LoopbackTransferTests.makeDirectory("rn-work")
        let media = content.appendingPathComponent("original.mp4")
        try LoopbackTransferTests.makePayload(bytes: 65_536).write(to: media)

        let torrentURL = work.appendingPathComponent("single.torrent")
        try TorrentEngine.createTorrentFile(
            describing: media, writingTo: torrentURL, pieceLength: 16_384)

        let session = try TorrentSession(configuration: LoopbackTransferTests.isolated)
        let hash = try await session.addTorrentFile(at: torrentURL, savePath: content)
        _ = await TorrentSessionTests.firstEvent(from: session) { event in
            if case .torrentAdded = event { return true }
            return false
        }
        return (session, hash, content, [content, work])
    }

    /// A multi-file torrent, where the name is the containing folder.
    static func makeMultiFile() async throws -> (
        session: TorrentSession, hash: InfoHash, save: URL, directories: [URL]
    ) {
        let root = try LoopbackTransferTests.makeDirectory("rn-multi")
        let work = try LoopbackTransferTests.makeDirectory("rn-multi-work")
        let bundle = root.appendingPathComponent("Original Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for name in ["a.bin", "b.bin"] {
            try LoopbackTransferTests.makePayload(bytes: 32_768)
                .write(to: bundle.appendingPathComponent(name))
        }

        let torrentURL = work.appendingPathComponent("multi.torrent")
        try TorrentEngine.createTorrentFile(
            describing: bundle, writingTo: torrentURL, pieceLength: 16_384)

        let session = try TorrentSession(configuration: LoopbackTransferTests.isolated)
        let hash = try await session.addTorrentFile(at: torrentURL, savePath: root)
        _ = await TorrentSessionTests.firstEvent(from: session) { event in
            if case .torrentAdded = event { return true }
            return false
        }
        return (session, hash, root, [root, work])
    }

    private static func cleanUp(_ session: TorrentSession, _ directories: [URL]) {
        Task { await session.shutdown() }
        for url in directories { try? FileManager.default.removeItem(at: url) }
    }

    @Test(.timeLimit(.minutes(1)))
    func renamingASingleFileKeepsItsExtension() async throws {
        let (session, hash, save, directories) = try await Self.makeSingleFile()
        defer { Self.cleanUp(session, directories) }

        try await session.renameContent(of: hash, to: "Renamed Movie")

        let event = await TorrentSessionTests.firstEvent(from: session) { event in
            if case .contentRenamed = event { return true }
            if case .contentRenameFailed = event { return true }
            return false
        }
        guard case .contentRenamed? = event else {
            Issue.record("rename did not report success: \(String(describing: event))")
            return
        }

        // The extension must survive, or the file stops being playable.
        let renamed = save.appendingPathComponent("Renamed Movie.mp4")
        var exists = false
        for _ in 0..<40 {
            exists = FileManager.default.fileExists(atPath: renamed.path)
            if exists { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(exists, "expected Renamed Movie.mp4 on disk")
        #expect(await session.files(of: hash).first?.name == "Renamed Movie.mp4")
    }

    @Test(.timeLimit(.minutes(1)))
    func renamingAMultiFileTorrentRenamesTheFolder() async throws {
        let (session, hash, save, directories) = try await Self.makeMultiFile()
        defer { Self.cleanUp(session, directories) }

        try await session.renameContent(of: hash, to: "New Folder")

        var moved = false
        for _ in 0..<40 {
            let paths = await session.files(of: hash).map(\.path)
            // Every file's path should now start with the new folder.
            moved = !paths.isEmpty && paths.allSatisfy { $0.hasPrefix("New Folder/") }
            if moved { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(moved, "every file should sit under the renamed folder")

        var onDisk = false
        for _ in 0..<40 {
            onDisk = FileManager.default.fileExists(
                atPath: save.appendingPathComponent("New Folder/a.bin").path)
            if onDisk { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(onDisk, "the folder should be renamed on disk too")
    }

    @Test func rejectsNamesThatCouldEscapeTheSavePath() async throws {
        let (session, hash, _, directories) = try await Self.makeSingleFile()
        defer { Self.cleanUp(session, directories) }

        for bad in ["", "..", ".", "../escape", "sub/dir"] {
            await #expect(throws: TorrentError.self, "should reject \(bad)") {
                try await session.renameContent(of: hash, to: bad)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func movingStorageRelocatesTheFilesAndUpdatesTheSavePath() async throws {
        let (session, hash, save, directories) = try await Self.makeSingleFile()
        let destination = try LoopbackTransferTests.makeDirectory("rn-dest")
        defer {
            Self.cleanUp(session, directories + [destination])
        }

        try await session.moveStorage(of: hash, to: destination)

        let event = await TorrentSessionTests.firstEvent(
            from: session, timeout: .seconds(30)
        ) { event in
            if case .storageMoved = event { return true }
            if case .storageMoveFailed = event { return true }
            return false
        }
        guard case .storageMoved? = event else {
            Issue.record("move did not report success: \(String(describing: event))")
            return
        }

        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("original.mp4").path),
            "the file should be at the destination")
        #expect(!FileManager.default.fileExists(
            atPath: save.appendingPathComponent("original.mp4").path),
            "the file should no longer be at the old path")
    }
}
