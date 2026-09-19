import Foundation
import Testing

@testable import TorrentKit

/// Talks to the real BitTorrent network, so it is opt-in:
///
///     TORRENTKIT_LIVE_TESTS=1 swift test
///
/// Everything else in the suite is offline. These are excluded by default
/// because they depend on public trackers and peers being reachable, which
/// makes them unsuitable as a gate on every change.
@Suite("Live network", .enabled(if: ProcessInfo.processInfo.environment["TORRENTKIT_LIVE_TESTS"] == "1"))
struct LiveDownloadTests {

    /// Debian's netinst image. Well seeded and served over a stable URL, which
    /// is why it is the fixture; the full ISO is ~700 MB, so the test below
    /// verifies the first pieces rather than pulling all of it.
    static let torrentURL = URL(
        string: "https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/debian-13.7.0-amd64-netinst.iso.torrent"
    )!

    static func downloadTorrentFile() async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: torrentURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TorrentError.engine("could not fetch the test torrent")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("debian-live-\(UUID().uuidString).torrent")
        try data.write(to: url)
        return url
    }

    /// Connects to the swarm and verifies real pieces, then stops. Proves the
    /// whole chain — tracker announce, peer handshake, piece download, hash
    /// check — without pulling the entire image.
    @Test(.timeLimit(.minutes(5)))
    func downloadsAndVerifiesFirstPieces() async throws {
        let torrent = try await Self.downloadTorrentFile()
        let savePath = try TorrentSessionTests.makeScratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: torrent)
            try? FileManager.default.removeItem(at: savePath)
        }

        // A real session this time: DHT and local discovery on, ephemeral port
        // so it cannot collide with a client already running on this machine.
        let configuration = SessionConfiguration(
            listenInterfaces: "0.0.0.0:0,[::]:0",
            isUPnPEnabled: false,
            isNATPMPEnabled: false
        )
        let session = try TorrentSession(configuration: configuration)
        defer { Task { await session.shutdown() } }

        try await session.addTorrentFile(at: torrent, savePath: savePath)
        await session.startPollingStatus(every: .seconds(1))

        var sawPeers = false
        var verifiedBytes: Int64 = 0

        // libtorrent verifies each piece's SHA-1 before counting it in
        // totalWantedDone, so any progress here is cryptographically checked.
        for await event in session.events {
            guard case .statusUpdated(let status) = event else {
                if case .torrentFailed(_, let message) = event {
                    Issue.record("torrent failed: \(message)")
                    return
                }
                continue
            }
            if status.peerCount > 0 { sawPeers = true }
            verifiedBytes = status.totalWantedDone
            if verifiedBytes >= 1_048_576 { break }
        }

        #expect(sawPeers, "never connected to a peer")
        #expect(verifiedBytes >= 1_048_576, "verified only \(verifiedBytes) bytes")
    }

    /// Exercises the magnet path against the DHT: no .torrent file, so the
    /// metadata has to arrive from peers.
    @Test(.timeLimit(.minutes(5)))
    func resolvesMagnetMetadataFromTheSwarm() async throws {
        let savePath = try TorrentSessionTests.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: savePath) }

        let torrent = try await Self.downloadTorrentFile()
        defer { try? FileManager.default.removeItem(at: torrent) }
        // Derive the magnet from the real torrent so the hash cannot go stale
        // when Debian publishes a new point release.
        let session = try TorrentSession(
            configuration: SessionConfiguration(listenInterfaces: "0.0.0.0:0,[::]:0",
                                                isUPnPEnabled: false,
                                                isNATPMPEnabled: false))
        defer { Task { await session.shutdown() } }

        let fileHash = try await session.addTorrentFile(at: torrent, savePath: savePath)
        try await session.remove(fileHash)

        let magnetHash = try await session.addMagnet(
            "magnet:?xt=urn:btih:\(fileHash.value)", savePath: savePath)
        #expect(magnetHash == fileHash)

        let event = await TorrentSessionTests.firstEvent(
            from: session, timeout: .seconds(180)
        ) { event in
            if case .metadataReceived = event { return true }
            if case .torrentAdded(let status) = event { return status.hasMetadata }
            return false
        }
        #expect(event != nil, "metadata never arrived from the swarm")
    }
}
