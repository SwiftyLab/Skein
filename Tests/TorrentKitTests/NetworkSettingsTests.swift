import Foundation
import Testing

@testable import TorrentKit

@Suite("Network and privacy settings")
struct NetworkSettingsTests {

    @Test func startsWithEncryptionRequiredAndPEXDisabled() async throws {
        var configuration = SessionConfiguration.offline
        configuration.encryption = .required
        configuration.isPEXEnabled = false

        // Opting out of PEX means opting out of libtorrent's default plugin
        // set, so this proves the session still constructs after doing so.
        let session = try TorrentSession(configuration: configuration)
        defer { Task { await session.shutdown() } }
        #expect(await session.listenPort >= 0)
    }

    @Test func appliesSettingsToARunningSession() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }

        var updated = SessionConfiguration.offline
        updated.downloadRateLimit = 262_144
        updated.uploadRateLimit = 65_536
        updated.encryption = .required
        updated.maxActiveDownloads = 3
        updated.maxActiveSeeds = 2
        updated.maxConnections = 120
        try await session.apply(updated)
    }

    @Test func acceptsEachProxyKind() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }

        for kind in ProxyKind.allCases {
            var configuration = SessionConfiguration.offline
            configuration.proxy = ProxyConfiguration(
                kind: kind, host: "127.0.0.1", port: 9_050,
                username: kind == .socks5 ? "user" : "",
                password: kind == .socks5 ? "secret" : "")
            // Nothing is listening on that port; the point is that libtorrent
            // accepts the configuration, not that it connects.
            try await session.apply(configuration)
        }
    }

    @Test func blocksAddressRangesInBothFamilies() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }

        try await session.setBlockedRanges([
            "10.0.0.0/8",
            "192.168.1.0/24",
            "203.0.113.42/32",
            "2001:db8::/32",
        ])
        // An empty list clears the filter rather than erroring.
        try await session.setBlockedRanges([])
    }

    @Test func rejectsMalformedBlockRanges() async throws {
        let session = try TorrentSession(configuration: .offline)
        defer { Task { await session.shutdown() } }

        // Missing prefix length.
        await #expect(throws: TorrentError.self) {
            try await session.setBlockedRanges(["10.0.0.1"])
        }
        // Not an address at all.
        await #expect(throws: TorrentError.self) {
            try await session.setBlockedRanges(["definitely-not-an-ip/24"])
        }
    }
}
