import Foundation
import Testing

@testable import TorrentKit

/// Tracker summaries across listen sockets, and the diagnostics report.
@Suite("Diagnostics")
struct DiagnosticsTests {

    // MARK: - Tracker summary

    private static let skipped = TrackerEndpoint(
        localEndpoint: "[::1]:6881", isSkipped: true,
        lastError: "skipping tracker announce (unreachable)")

    @Test func workingSocketWinsOverSkippedOnes() {
        let tracker = TorrentTracker(url: "udp://tracker.example:1337/announce", endpoints: [
            Self.skipped,
            TrackerEndpoint(localEndpoint: "192.168.1.5:6881", hasAnnounced: true, seeds: 12),
            Self.skipped,
        ])
        #expect(tracker.isWorking)
        #expect(tracker.lastError == nil)
        #expect(tracker.peerCount == 12)
    }

    /// The regression behind "download stuck at 0%": the last socket's skip
    /// used to overwrite the real error from an earlier one.
    @Test func realErrorIsNotHiddenBySkippedSockets() {
        let tracker = TorrentTracker(url: "udp://tracker.example:1337/announce", endpoints: [
            TrackerEndpoint(localEndpoint: "192.168.1.5:6881", lastError: "timed out", fails: 3),
            Self.skipped,
        ])
        #expect(!tracker.isWorking)
        #expect(tracker.lastError == "timed out")
    }

    @Test func everySocketSkippedReadsAsUnreachable() {
        let tracker = TorrentTracker(
            url: "udp://tracker.example:1337/announce", endpoints: [Self.skipped, Self.skipped])
        #expect(tracker.lastError == TorrentTracker.unreachableMessage)
    }

    @Test func skippedPlusPendingIsNotAnError() {
        let tracker = TorrentTracker(url: "udp://tracker.example:1337/announce", endpoints: [
            Self.skipped,
            TrackerEndpoint(localEndpoint: "192.168.1.5:6881", isUpdating: true),
        ])
        #expect(!tracker.isWorking)
        #expect(tracker.lastError == nil)
    }

    @Test func noSocketsYetIsNotAnError() {
        let tracker = TorrentTracker(url: "udp://tracker.example:1337/announce", endpoints: [])
        #expect(tracker.lastError == nil)
        #expect(tracker.peerCount == 0)
    }

    @Test func failedAnnounceAfterSuccessIsNotWorking() {
        // start_sent stays set after a later announce fails; the error wins.
        let endpoint = TrackerEndpoint(
            localEndpoint: "192.168.1.5:6881", hasAnnounced: true, lastError: "timed out")
        #expect(!endpoint.isWorking)
        #expect(TorrentTracker(url: "http://t.example/announce", endpoints: [endpoint])
            .lastError == "timed out")
    }

    // MARK: - Redaction

    @Test func redactedURLDropsPasskeys() {
        func redacted(_ url: String) -> String {
            TorrentTracker(url: url, endpoints: []).redactedURL
        }
        #expect(redacted("udp://tracker.example:1337/announce") == "udp://tracker.example:1337/announce")
        #expect(redacted("https://private.example/abcdef123456/announce") == "https://private.example/…")
        #expect(redacted("https://private.example/announce?passkey=secret") == "https://private.example/…")
        #expect(!redacted("https://private.example/announce.php?passkey=secret").contains("secret"))
    }

    @Test func reportListsEverySocketWithoutTorrentNamesOrPasskeys() {
        let tracker = TorrentTracker(url: "https://private.example/announce?passkey=secret", endpoints: [
            TrackerEndpoint(localEndpoint: "192.168.1.5:6881", lastError: "timed out", fails: 2),
            Self.skipped,
        ])
        let lines = DiagnosticsReport.describe(tracker)
        let text = lines.joined(separator: "\n")
        #expect(!text.contains("secret"))
        #expect(text.contains("failing: timed out"))
        #expect(text.contains("192.168.1.5:6881 v1: error: timed out fails 2"))
        #expect(text.contains("[::1]:6881 v1: skipped (cannot route)"))
    }

    // MARK: - Live session

    /// A tracker on a closed loopback port: the loopback listen socket can
    /// route to it, so it must show a real error, not a skip.
    @Test func trackerReportsPerSocketResults() async throws {
        let session = try TorrentSession(configuration: LoopbackTransferTests.isolated)
        defer { Task { await session.shutdown() } }
        let directory = try LoopbackTransferTests.makeDirectory("diagnostics")
        let magnet = "magnet:?xt=urn:btih:\(String(repeating: "ab", count: 20))"
            + "&tr=http%3A%2F%2F127.0.0.1%3A9%2Fannounce"
        let hash = try await session.addMagnet(magnet, savePath: directory)

        var tracker: TorrentTracker?
        for _ in 0..<100 {
            tracker = await session.trackers(of: hash).first
            if tracker?.lastError != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = try #require(tracker)
        #expect(result.url == "http://127.0.0.1:9/announce")
        let endpoint = try #require(result.endpoints.first)
        #expect(endpoint.localEndpoint.hasPrefix("127.0.0.1:"))
        #expect(!endpoint.isSkipped)
        #expect(result.lastError != nil)
        #expect(result.lastError != TorrentTracker.unreachableMessage)
    }

    /// Tracker and torrent alerts carry the URL and name verbatim; neither may
    /// reach the shareable event log.
    @Test func eventLogHidesTorrentNamesAndPasskeys() async throws {
        let session = try TorrentSession(configuration: LoopbackTransferTests.isolated)
        defer { Task { await session.shutdown() } }
        let directory = try LoopbackTransferTests.makeDirectory("diagnostics-redaction")
        let magnet = "magnet:?xt=urn:btih:\(String(repeating: "cd", count: 20))"
            + "&dn=Secret%20Holiday%20Video"
            + "&tr=http%3A%2F%2F127.0.0.1%3A9%2Fsecretpasskey%2Fannounce"
        let hash = try await session.addMagnet(magnet, savePath: directory)

        var text = ""
        for _ in 0..<100 {
            text = await session.networkDiagnostics()
            if text.contains("tracker_error") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(text.contains("tracker_error"))
        #expect(text.contains("http://127.0.0.1:9/…"))
        #expect(!text.contains("secretpasskey"))
        #expect(!text.contains("Secret Holiday Video"))
        _ = hash
    }

    @Test func engineDiagnosticsCoverSocketsInterfacesAndEvents() async throws {
        let session = try TorrentSession(configuration: LoopbackTransferTests.isolated)
        defer { Task { await session.shutdown() } }
        // Let the listen alerts arrive.
        try await Task.sleep(for: .milliseconds(500))
        let text = await session.networkDiagnostics()

        #expect(text.contains("libtorrent 2."))
        #expect(text.contains("listen_interfaces: 127.0.0.1:0"))
        #expect(text.contains("## Interfaces"))
        #expect(text.contains("lo0"))
        #expect(text.contains("## Routes"))
        #expect(text.contains("## Listen sockets"))
        #expect(text.contains("127.0.0.1:"))
        #expect(text.contains("listening"))
        #expect(text.contains("peer.num_peers_connected"))
        #expect(text.contains("## Recent events"))
        #expect(text.contains("log:"))
    }
}
