import Foundation
import Testing

@testable import TorrentFeeds

@Suite("Feed rules")
struct FeedRuleTests {

    @Test func emptyIncludesMatchesEverything() {
        let rule = FeedRule(name: "all")
        #expect(rule.matches("Anything At All"))
    }

    @Test func includesAreCaseInsensitiveSubstrings() {
        let rule = FeedRule(name: "iso", includes: ["debian"])
        #expect(rule.matches("Debian 13 netinst"))
        #expect(rule.matches("DEBIAN testing"))
        #expect(!rule.matches("Ubuntu 26.04"))
    }

    @Test func excludesOverrideIncludes() {
        // The common shape: take a broad category, drop one variant.
        let rule = FeedRule(name: "iso", includes: ["debian"], excludes: ["arm64"])
        #expect(rule.matches("Debian amd64"))
        #expect(!rule.matches("Debian arm64"))
    }

    @Test func excludesApplyEvenWithNoIncludes() {
        let rule = FeedRule(name: "not beta", excludes: ["beta"])
        #expect(rule.matches("Stable release"))
        #expect(!rule.matches("Beta release"))
    }

    @Test func regularExpressionsMatchWhenEnabled() {
        let rule = FeedRule(
            name: "seasons", includes: [#"S0[12]E\d{2}"#], usesRegularExpressions: true)
        #expect(rule.matches("Show.S01E05.1080p"))
        #expect(rule.matches("Show.S02E12.720p"))
        #expect(!rule.matches("Show.S03E01.1080p"))
    }

    @Test func invalidRegularExpressionMatchesNothingRatherThanCrashing() {
        // One malformed rule must not take down the whole feed.
        let rule = FeedRule(name: "bad", includes: ["[unclosed"], usesRegularExpressions: true)
        #expect(!rule.matches("anything"))
    }

    @Test func disabledRuleNeverMatches() {
        let rule = FeedRule(name: "off", isEnabled: false)
        #expect(!rule.matches("Debian"))
    }
}

@Suite("Feed parsing")
struct FeedParsingTests {

    static func rss(_ itemsXML: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
        <title>Test Tracker</title><link>https://example.invalid</link>
        <description>d</description>
        \(itemsXML)
        </channel></rss>
        """.utf8)
    }

    @Test func readsMagnetLinksFromTheLinkElement() throws {
        let data = Self.rss("""
        <item><title>Debian 13 amd64</title>
        <link>magnet:?xt=urn:btih:2b66980093bc11806fab50cb3cb41835b95a0362</link>
        <guid>item-1</guid></item>
        """)
        let parsed = try FeedDocumentParser.parse(data)
        #expect(parsed.title == "Test Tracker")
        #expect(parsed.items.count == 1)
        let item = try #require(parsed.items.first)
        #expect(item.title == "Debian 13 amd64")
        #expect(item.isMagnet)
    }

    @Test func fallsBackToTheGUIDForTheMagnet() throws {
        // Some trackers only put the magnet in the GUID.
        let data = Self.rss("""
        <item><title>Only in guid</title>
        <guid>magnet:?xt=urn:btih:2b66980093bc11806fab50cb3cb41835b95a0362</guid></item>
        """)
        let parsed = try FeedDocumentParser.parse(data)
        #expect(parsed.items.first?.isMagnet == true)
    }

    @Test func prefersAnEnclosureOverTheLink() throws {
        // The link is usually a human-facing page; the enclosure is the file.
        let data = Self.rss("""
        <item><title>With enclosure</title>
        <link>https://example.invalid/details/1</link>
        <enclosure url="https://example.invalid/file.torrent" type="application/x-bittorrent"/>
        <guid>item-2</guid></item>
        """)
        let parsed = try FeedDocumentParser.parse(data)
        #expect(parsed.items.first?.link.absoluteString == "https://example.invalid/file.torrent")
    }

    @Test func skipsItemsWithNoUsableLink() throws {
        let data = Self.rss("<item><title>No link here</title></item>")
        let parsed = try FeedDocumentParser.parse(data)
        #expect(parsed.items.isEmpty)
    }

    @Test func rejectsMalformedXML() {
        #expect(throws: (any Error).self) {
            try FeedDocumentParser.parse(Data("this is not xml".utf8))
        }
    }
}

/// Records what it was asked to add, so the monitor can be tested without a
/// real engine or network.
private actor RecordingAdder: TorrentAdding {
    private(set) var magnets: [String] = []
    private(set) var torrents: [URL] = []
    var failNext = false

    func addMagnet(_ uri: String, savePath: URL?) async throws {
        if failNext { failNext = false; throw FeedDocumentParser.ParseError.unsupportedFormat }
        magnets.append(uri)
    }

    func addTorrent(from url: URL, savePath: URL?) async throws {
        torrents.append(url)
    }

    func setFailNext(_ value: Bool) { failNext = value }
}

@Suite("Feed store")
struct FeedStoreTests {

    static func makeStore() throws -> (FeedStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feeds-\(UUID().uuidString)")
        return (try FeedStore(directory: directory), directory)
    }

    @Test func persistsFeedsAcrossInstances() async throws {
        let (store, directory) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let feed = Feed(
            title: "Tracker",
            url: URL(string: "https://example.invalid/rss")!,
            rules: [FeedRule(name: "iso", includes: ["debian"])])
        await store.add(feed)

        let reopened = try FeedStore(directory: directory)
        let loaded = await reopened.feeds()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Tracker")
        #expect(loaded.first?.rules.first?.includes == ["debian"])
    }

    @Test func updatesAndRemovesFeeds() async throws {
        let (store, directory) = try Self.makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var feed = Feed(title: "One", url: URL(string: "https://example.invalid/a")!)
        await store.add(feed)
        feed.title = "Renamed"
        await store.update(feed)
        #expect(await store.feeds().first?.title == "Renamed")

        await store.remove(feed.id)
        #expect(await store.feeds().isEmpty)
    }

    @Test func reportsWhenAFeedIsDue() {
        let feed = Feed(
            title: "t", url: URL(string: "https://example.invalid")!,
            refreshInterval: 600, lastChecked: Date(timeIntervalSinceNow: -300))
        #expect(!feed.isDue())

        let stale = Feed(
            title: "t", url: URL(string: "https://example.invalid")!,
            refreshInterval: 600, lastChecked: Date(timeIntervalSinceNow: -900))
        #expect(stale.isDue())

        let disabled = Feed(
            title: "t", url: URL(string: "https://example.invalid")!,
            isEnabled: false, lastChecked: nil)
        #expect(!disabled.isDue())
    }
}
