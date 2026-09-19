import Foundation
import Testing

@testable import TorrentKit

/// Exercises session lifecycle without touching the network.
///
/// Every session here uses `.offline`: no DHT, no local discovery, no port
/// mapping, and an ephemeral loopback port, so the suite neither contacts a
/// swarm nor fights over port 6881 with a running client.
@Suite("Session")
struct TorrentSessionTests {

    /// A well-formed single-file torrent, built by hand so the suite needs no
    /// fixture file on disk. The tracker is unreachable on purpose — nothing
    /// here should ever announce.
    static func makeTorrentFile() throws -> URL {
        // One 16 KiB piece of zeros, plus its SHA-1, which libtorrent verifies.
        let pieceLength = 16_384
        let contents = Data(repeating: 0, count: pieceLength)
        let pieceHash = Data(SHA1.hash(contents))

        let torrent = BEncode.dictionary([
            "announce": .string("http://127.0.0.1:1/announce"),
            "info": .dictionary([
                "length": .integer(contents.count),
                "name": .string("torrentkit-test.bin"),
                "piece length": .integer(pieceLength),
                "pieces": .bytes(pieceHash),
            ]),
        ])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-\(UUID().uuidString).torrent")
        try torrent.encoded.write(to: url)
        return url
    }

    static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Waits for the first event matching `predicate`, or fails on timeout.
    /// Prevents a broken pump from hanging the whole suite.
    static func firstEvent(
        from session: TorrentSession,
        timeout: Duration = .seconds(20),
        matching predicate: @escaping @Sendable (SessionEvent) -> Bool
    ) async -> SessionEvent? {
        await withTaskGroup(of: SessionEvent?.self) { group in
            group.addTask {
                for await event in session.events where predicate(event) { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test func startsAndStopsCleanly() async throws {
        let session = try TorrentSession(configuration: .offline)
        await session.shutdown()
        // Second call must be a no-op rather than a crash or a hang.
        await session.shutdown()
    }

    @Test func addingTorrentFileEmitsTorrentAdded() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }

        let torrent = try Self.makeTorrentFile()
        let savePath = try Self.makeScratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: torrent)
            try? FileManager.default.removeItem(at: savePath)
        }

        let infoHash = try await session.addTorrentFile(at: torrent, savePath: savePath)
        #expect(infoHash.value.count == 40, "info hash should be 40 hex characters")

        let event = await Self.firstEvent(from: session) { event in
            if case .torrentAdded = event { return true }
            return false
        }
        guard case .torrentAdded(let status)? = event else {
            Issue.record("no torrentAdded event arrived")
            return
        }
        #expect(status.infoHash == infoHash)
        #expect(status.name == "torrentkit-test.bin")
        #expect(status.hasMetadata)
    }

    @Test func addingMagnetLinkYieldsItsInfoHash() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }

        let savePath = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: savePath) }

        // Debian's published magnet hash; nothing is downloaded, since this
        // session is offline. Proves magnet parsing and the add path.
        let hex = "2b66980093bc11806fab50cb3cb41835b95a0362"
        let infoHash = try await session.addMagnet(
            "magnet:?xt=urn:btih:\(hex)&dn=test", savePath: savePath)
        #expect(infoHash.value == hex)
    }

    @Test func rejectsMalformedMagnetLink() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }
        let savePath = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: savePath) }

        // libtorrent throws here; reaching Swift as an error rather than an
        // abort is the whole point of the facade's catch-all.
        await #expect(throws: TorrentError.self) {
            try await session.addMagnet("magnet:?xt=urn:btih:nonsense", savePath: savePath)
        }
    }

    @Test func operationsFailAfterShutdown() async throws {
        let session = try TorrentSession(configuration: .offline)
        await session.shutdown()
        let savePath = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: savePath) }

        await #expect(throws: TorrentError.sessionStopped) {
            try await session.addMagnet(
                "magnet:?xt=urn:btih:2b66980093bc11806fab50cb3cb41835b95a0362",
                savePath: savePath)
        }
    }

    @Test func pausingAnUnknownTorrentReportsAnError() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }

        await #expect(throws: TorrentError.self) {
            try await session.pause(InfoHash(String(repeating: "0", count: 40)))
        }
    }

    @Test func statusUpdatesArriveForAnAddedTorrent() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }

        let torrent = try Self.makeTorrentFile()
        let savePath = try Self.makeScratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: torrent)
            try? FileManager.default.removeItem(at: savePath)
        }

        try await session.addTorrentFile(at: torrent, savePath: savePath)
        await session.startPollingStatus(every: .milliseconds(200))

        let event = await Self.firstEvent(from: session) { event in
            if case .statusUpdated = event { return true }
            return false
        }
        guard case .statusUpdated(let status)? = event else {
            Issue.record("no statusUpdated event arrived")
            return
        }
        #expect(status.name == "torrentkit-test.bin")
    }
}

/// A bencode writer, just enough to build a .torrent fixture.
///
/// Modelled as an enum rather than `Any`, because an array of tuples cannot be
/// dynamically cast out of an existential in Swift.
indirect enum BEncode {
    case integer(Int)
    case string(String)
    case bytes(Data)
    case list([BEncode])
    case dictionary([String: BEncode])

    var encoded: Data {
        switch self {
        case .integer(let value):
            return Data("i\(value)e".utf8)
        case .string(let value):
            return Self.encode(bytes: Data(value.utf8))
        case .bytes(let value):
            return Self.encode(bytes: value)
        case .list(let elements):
            return Data("l".utf8) + elements.map(\.encoded).reduce(Data(), +) + Data("e".utf8)
        case .dictionary(let pairs):
            // Bencode requires dictionary keys in sorted order; libtorrent
            // rejects the file otherwise.
            let body = pairs.sorted { $0.key < $1.key }
                .map { Self.encode(bytes: Data($0.key.utf8)) + $0.value.encoded }
                .reduce(Data(), +)
            return Data("d".utf8) + body + Data("e".utf8)
        }
    }

    private static func encode(bytes: Data) -> Data {
        Data("\(bytes.count):".utf8) + bytes
    }
}

/// Minimal SHA-1, so the fixture builder does not depend on CryptoKit's
/// deprecated `Insecure.SHA1` spelling.
enum SHA1 {
    static func hash(_ message: Data) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var padded = [UInt8](message)
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(padded[base]) << 24) | (UInt32(padded[base + 1]) << 16)
                    | (UInt32(padded[base + 2]) << 8) | UInt32(padded[base + 3])
            }
            for i in 16..<80 {
                let value = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (value << 1) | (value >> 31)
            }

            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20:  (f, k) = ((b & c) | (~b & d), 0x5A82_7999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9_EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default:      (f, k) = (b ^ c ^ d, 0xCA62_C1D6)
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, (b << 30) | (b >> 2), a, temp)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }

        return h.flatMap { word in
            (0..<4).map { UInt8((word >> (24 - $0 * 8)) & 0xFF) }
        }
    }
}
