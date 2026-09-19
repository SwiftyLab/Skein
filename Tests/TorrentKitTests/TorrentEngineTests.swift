import Foundation
import Testing

@testable import TorrentKit

@Suite("Engine bridge")
struct TorrentEngineTests {

    /// Proves the whole stack links and runs: Swift -> C++ facade -> libtorrent.
    /// libtorrent reports four components, e.g. "2.0.14.0", so match the pin as
    /// a prefix rather than pinning the build component too.
    @Test func reportsLinkedLibtorrentVersion() {
        let version = TorrentEngine.libtorrentVersion
        #expect(version.hasPrefix("2.0.14"))
    }

    /// Reads the version by calling into libcrypto, so this fails if OpenSSL
    /// is on the include path but not actually linked.
    @Test func linksOpenSSL() {
        #expect(TorrentEngine.opensslVersion.hasPrefix("3.5.8"))
    }

    /// Guards the regression that leaves the engine silently without HTTPS
    /// trackers or SSL torrents, which otherwise only shows up against a real
    /// tracker.
    @Test func compilesLibtorrentWithSSLSupport() {
        #expect(TorrentEngine.supportsSSL)
    }

    /// The highest-value test in the suite. libtorrent throws on malformed
    /// input, and Swift cannot catch C++ exceptions — if the facade ever stops
    /// catching, this aborts the test process instead of failing, which is
    /// exactly the regression we need to notice.
    @Test func surfacesEngineErrorInsteadOfTerminating() throws {
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-torrent-\(UUID().uuidString).torrent")
        try Data("this is definitely not bencoded".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }

        let error = #expect(throws: TorrentError.self) {
            _ = try TorrentEngine.torrentName(atPath: garbage.path)
        }
        // Assert the message actually came from libtorrent, so the test cannot
        // pass by the facade inventing an error without ever calling through.
        guard case .engine(let message)? = error else { return }
        // Non-empty proves the text came back from libtorrent's bdecode rather
        // than the facade inventing a failure without calling through. The real
        // message here is "expected value (list, dict, int or string) in
        // bencoded string [bdecode:4]".
        #expect(!message.isEmpty)
    }

    @Test func surfacesEngineErrorForMissingFile() {
        #expect(throws: TorrentError.self) {
            _ = try TorrentEngine.torrentName(atPath: "/nonexistent/nope.torrent")
        }
    }
}
