import Foundation
import Testing

@testable import TorrentKit

/// Proves the engine actually moves and verifies data, by running a seeder and
/// a leecher in one process and introducing them to each other over loopback.
///
/// No tracker, no DHT, no internet: the torrent is trackerless and the peer is
/// added by hand. That makes this deterministic enough to run on every change,
/// unlike the public-swarm tests in `LiveDownloadTests`.
@Suite("Loopback transfer")
struct LoopbackTransferTests {

    /// Loopback-only, so neither session can reach or be reached by the outside
    /// world, and an ephemeral port so tests never collide.
    static var isolated: SessionConfiguration {
        SessionConfiguration(
            listenInterfaces: "127.0.0.1:0",
            isDHTEnabled: false,
            isLocalDiscoveryEnabled: false,
            isUPnPEnabled: false,
            isNATPMPEnabled: false
        )
    }

    static func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Pseudo-random but reproducible, and incompressible enough that the
    /// transfer is doing real work.
    static func makePayload(bytes: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data(capacity: bytes)
        while data.count < bytes {
            withUnsafeBytes(of: generator.next()) { data.append(contentsOf: $0) }
        }
        return data.prefix(bytes)
    }

    @Test(.timeLimit(.minutes(1)))
    func leecherDownloadsAndVerifiesFromSeeder() async throws {
        let seedDirectory = try Self.makeDirectory("seed")
        let leechDirectory = try Self.makeDirectory("leech")
        let workDirectory = try Self.makeDirectory("work")
        defer {
            for url in [seedDirectory, leechDirectory, workDirectory] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // 2 MiB across 64 pieces of 32 KiB, so progress is observable rather
        // than completing in a single piece.
        let payload = Self.makePayload(bytes: 2 * 1_048_576)
        let contentURL = seedDirectory.appendingPathComponent("payload.bin")
        try payload.write(to: contentURL)

        let torrentURL = workDirectory.appendingPathComponent("payload.torrent")
        try TorrentEngine.createTorrentFile(
            describing: contentURL, writingTo: torrentURL, pieceLength: 32_768)

        // The seeder already has the data, so its recheck completes instantly
        // and it goes straight to seeding.
        let seeder = try TorrentSession(configuration: Self.isolated)
        let leecher = try TorrentSession(configuration: Self.isolated)
        defer {
            Task {
                await seeder.shutdown()
                await leecher.shutdown()
            }
        }

        let seedHash = try await seeder.addTorrentFile(at: torrentURL, savePath: seedDirectory)
        let leechHash = try await leecher.addTorrentFile(at: torrentURL, savePath: leechDirectory)
        #expect(seedHash == leechHash, "both sides must agree on the info hash")

        await seeder.startPollingStatus(every: .milliseconds(250))
        await leecher.startPollingStatus(every: .milliseconds(250))

        let seederPort = await seeder.listenPort
        #expect(seederPort > 0, "seeder did not bind a port")

        // Introduce them directly; there is no tracker or DHT to do it for us.
        // Retried because the seeder must finish checking its files first.
        var connected = false
        for _ in 0..<40 where !connected {
            try? await leecher.addPeer(leechHash, host: "127.0.0.1", port: seederPort)
            try await Task.sleep(for: .milliseconds(250))
            let peers = await Self.currentPeerCount(of: leecher)
            connected = peers > 0
        }

        var completed = false
        var lastProgress = 0.0
        for await event in leecher.events {
            if case .torrentFinished = event { completed = true; break }
            guard case .statusUpdated(let status) = event else { continue }
            lastProgress = status.progress
            // totalWantedDone only counts pieces whose SHA-1 libtorrent has
            // verified, so reaching the full size proves the data is intact.
            if status.totalWantedDone >= Int64(payload.count) { completed = true; break }
        }

        #expect(completed, "transfer stalled at \(Int(lastProgress * 100))%")

        // The decisive check: bytes on disk match what the seeder held.
        let received = try Data(
            contentsOf: leechDirectory.appendingPathComponent("payload.bin"))
        #expect(received.count == payload.count)
        #expect(received == payload, "downloaded data differs from the original")
    }

    private static func currentPeerCount(of session: TorrentSession) async -> Int {
        await session.requestStatusUpdates()
        let event = await TorrentSessionTests.firstEvent(
            from: session, timeout: .seconds(2)
        ) { event in
            if case .statusUpdated = event { return true }
            return false
        }
        if case .statusUpdated(let status)? = event { return status.peerCount }
        return 0
    }
}
