import Foundation
import Testing

@testable import TorrentFeeds

/// Records what it was asked to add, so the monitor is testable without an
/// engine or a network.
private actor RecordingAdder: TorrentAdding {
    private(set) var magnets: [String] = []
    private(set) var torrents: [URL] = []
    private var failuresRemaining = 0

    func failNextAdds(_ count: Int) { failuresRemaining = count }

    func addMagnet(_ uri: String, savePath: URL?) async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw FeedDocumentParser.ParseError.unsupportedFormat
        }
        magnets.append(uri)
    }

    func addTorrent(from url: URL, savePath: URL?) async throws {
        torrents.append(url)
    }
}

@Suite("Feed monitor")
struct FeedMonitorTests {

    /// Feeds are fetched with URLSession, which handles file URLs — so a feed
    /// can be served from disk with no network and no stub server.
    static func writeFeed(_ titles: [String], to directory: URL) throws -> URL {
        let items = titles.enumerated().map { index, title in
            """
            <item><title>\(title)</title>
            <guid>item-\(index)-\(title.hashValue)</guid>
            <link>magnet:?xt=urn:btih:\(String(format: "%040x", abs(title.hashValue)))</link>
            </item>
            """
        }.joined(separator: "\n")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Test</title>
        <link>https://example.invalid</link><description>d</description>
        \(items)
        </channel></rss>
        """
        let url = directory.appendingPathComponent("feed-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }

    fileprivate static func makeEnvironment() throws
        -> (RecordingAdder, FeedStore, FeedMonitor, URL)
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let adder = RecordingAdder()
        let store = try FeedStore(directory: directory)
        return (adder, store, FeedMonitor(adder: adder, store: store), directory)
    }

    @Test func addsEveryItemWhenNoRulesAreSet() async throws {
        let (adder, store, monitor, directory) = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let feedURL = try Self.writeFeed(["Alpha", "Beta", "Gamma"], to: directory)
        let feed = Feed(title: "Test", url: feedURL)
        await store.add(feed)

        let result = await monitor.check(feed)
        #expect(result.error == nil)
        #expect(result.matched.count == 3)
        #expect(await adder.magnets.count == 3)
    }

    @Test func honoursIncludeAndExcludeRules() async throws {
        let (adder, store, monitor, directory) = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let feedURL = try Self.writeFeed(
            ["Debian amd64", "Debian arm64", "Ubuntu amd64"], to: directory)
        let feed = Feed(
            title: "Test", url: feedURL,
            rules: [FeedRule(name: "r", includes: ["debian"], excludes: ["arm64"])])
        await store.add(feed)

        let result = await monitor.check(feed)
        #expect(result.matched.map(\.title) == ["Debian amd64"])
        #expect(await adder.magnets.count == 1)
    }

    /// The behaviour that keeps a long-lived feed from re-adding everything on
    /// every poll.
    @Test func doesNotReAddItemsItHasAlreadySeen() async throws {
        let (adder, store, monitor, directory) = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let feedURL = try Self.writeFeed(["Alpha", "Beta"], to: directory)
        let feed = Feed(title: "Test", url: feedURL)
        await store.add(feed)

        _ = await monitor.check(feed)
        #expect(await adder.magnets.count == 2)

        let second = await monitor.check(feed)
        #expect(second.matched.isEmpty)
        #expect(second.skippedAlreadySeen == 2)
        #expect(await adder.magnets.count == 2, "items must not be added twice")
    }

    /// A failed add must not be recorded as seen, or a transient error would
    /// silently drop the item forever.
    @Test func retriesItemsWhoseAddFailed() async throws {
        let (adder, store, monitor, directory) = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let feedURL = try Self.writeFeed(["Alpha"], to: directory)
        let feed = Feed(title: "Test", url: feedURL)
        await store.add(feed)

        await adder.failNextAdds(1)
        let first = await monitor.check(feed)
        #expect(first.matched.isEmpty)
        #expect(await adder.magnets.isEmpty)

        let second = await monitor.check(feed)
        #expect(second.matched.count == 1, "a failed add should be retried")
        #expect(await adder.magnets.count == 1)
    }

    @Test func recordsAnErrorForAnUnreachableFeed() async throws {
        let (_, store, monitor, directory) = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let feed = Feed(
            title: "Gone",
            url: directory.appendingPathComponent("does-not-exist.xml"))
        await store.add(feed)

        let result = await monitor.check(feed)
        #expect(result.error != nil)
        // Persisted, so the UI can show why a feed stopped working.
        #expect(await store.feeds().first?.lastError != nil)
    }

    @Test func checksOnlyFeedsThatAreDue() async throws {
        let (adder, store, monitor, directory) = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }

        let feedURL = try Self.writeFeed(["Alpha"], to: directory)
        // Checked a moment ago with a long interval, so it is not due.
        await store.add(Feed(
            title: "Fresh", url: feedURL, refreshInterval: 3_600,
            lastChecked: Date(timeIntervalSinceNow: -60)))
        // Never checked, so it is.
        await store.add(Feed(title: "Stale", url: feedURL, refreshInterval: 3_600))

        let results = await monitor.checkDueFeeds()
        #expect(results.count == 1)
        #expect(await adder.magnets.count == 1)
    }
}
