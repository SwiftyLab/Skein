import Foundation
import Observation
import TorrentFeeds
import TorrentKit

/// Owns the feed list and the polling monitor, exposing both to SwiftUI.
@MainActor
@Observable
public final class FeedCoordinator {
    public private(set) var feeds: [Feed] = []
    public private(set) var lastResults: [FeedCheckResult] = []

    private let store: FeedStore
    private let monitor: FeedMonitor

    public init(manager: TorrentManager) throws {
        let store = try FeedStore(directory: try FeedStore.defaultDirectory())
        self.store = store
        monitor = FeedMonitor(adder: ManagerAdder(manager: manager), store: store)
    }

    public func start() async {
        feeds = await store.feeds()
        await monitor.loadHistory()
        await monitor.startPolling(every: .seconds(60))
    }

    public func stop() async {
        await monitor.stopPolling()
    }

    public func save(_ feed: Feed) async {
        await store.update(feed)
        feeds = await store.feeds()
    }

    public func remove(_ feed: Feed) async {
        await store.remove(feed.id)
        feeds = await store.feeds()
    }

    /// Checks one feed immediately, ignoring its refresh interval.
    public func checkNow(_ feed: Feed) async {
        let result = await monitor.check(feed)
        lastResults.insert(result, at: 0)
        if lastResults.count > 20 { lastResults.removeLast() }
        feeds = await store.feeds()
    }
}

/// Adapts ``TorrentManager`` to the protocol the monitor depends on, so
/// `TorrentFeeds` stays independent of the app layer.
private struct ManagerAdder: TorrentAdding {
    let manager: TorrentManager

    func addMagnet(_ uri: String, savePath: URL?) async {
        await manager.addMagnet(uri, savePath: savePath)
    }

    func addTorrent(from url: URL, savePath: URL?) async throws {
        // Feed items usually point at a .torrent on a web server, so it has to
        // be fetched before the engine can be handed a local file.
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TorrentError.engine("HTTP \(http.statusCode) fetching \(url.lastPathComponent)")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-\(UUID().uuidString).torrent")
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        await manager.addTorrentFile(at: temporary, savePath: savePath)
    }
}
