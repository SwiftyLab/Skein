import Foundation
import TorrentKit

/// What a feed check decided to do.
public struct FeedCheckResult: Sendable {
    public let feedID: UUID
    public let matched: [FeedItem]
    public let skippedAlreadySeen: Int
    public let error: String?
}

/// Anything that can accept a torrent. Lets the monitor be tested without a
/// real session, and keeps `TorrentFeeds` from depending on the app layer.
public protocol TorrentAdding: Sendable {
    func addMagnet(_ uri: String, savePath: URL?) async throws
    func addTorrent(from url: URL, savePath: URL?) async throws
}

/// Polls feeds and adds whatever matches their rules.
///
/// Remembers the items it has already acted on, so a feed that keeps an entry
/// around for weeks does not re-add it on every poll.
public actor FeedMonitor {
    private let adder: any TorrentAdding
    private let store: FeedStore
    private var pollingTask: Task<Void, Never>?

    /// Per-feed history of item identifiers already downloaded.
    private var seen: [UUID: Set<String>] = [:]
    /// Capped so a long-lived feed's history cannot grow without bound.
    private static let maxRememberedPerFeed = 1_000

    public init(adder: any TorrentAdding, store: FeedStore) {
        self.adder = adder
        self.store = store
    }

    public func loadHistory() async {
        seen = await store.loadHistory()
    }

    /// Starts checking due feeds on a timer.
    public func startPolling(every interval: Duration = .seconds(60)) {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.checkDueFeeds()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Checks every feed whose refresh interval has elapsed.
    @discardableResult
    public func checkDueFeeds(now: Date = .now) async -> [FeedCheckResult] {
        var results: [FeedCheckResult] = []
        for feed in await store.feeds() where feed.isDue(now: now) {
            results.append(await check(feed))
        }
        return results
    }

    /// Fetches one feed and adds what matches, regardless of whether it is due.
    @discardableResult
    public func check(_ feed: Feed) async -> FeedCheckResult {
        var updated = feed
        updated.lastChecked = .now

        let data: Data
        do {
            let (fetched, response) = try await URLSession.shared.data(from: feed.url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FeedDocumentParser.ParseError.malformed("HTTP \(http.statusCode)")
            }
            data = fetched
        } catch {
            updated.lastError = String(describing: error)
            await store.update(updated)
            return FeedCheckResult(feedID: feed.id, matched: [],
                                   skippedAlreadySeen: 0, error: updated.lastError)
        }

        let items: [FeedItem]
        do {
            items = try FeedDocumentParser.parse(data).items
        } catch {
            updated.lastError = String(describing: error)
            await store.update(updated)
            return FeedCheckResult(feedID: feed.id, matched: [],
                                   skippedAlreadySeen: 0, error: updated.lastError)
        }

        var history = seen[feed.id] ?? []
        var matched: [FeedItem] = []
        var skipped = 0

        for item in items {
            guard feed.rules.isEmpty || feed.rules.contains(where: { $0.matches(item.title) })
            else { continue }
            if history.contains(item.id) {
                skipped += 1
                continue
            }
            do {
                if item.isMagnet {
                    try await adder.addMagnet(item.link.absoluteString,
                                              savePath: feed.downloadDirectory)
                } else {
                    try await adder.addTorrent(from: item.link,
                                               savePath: feed.downloadDirectory)
                }
                // Only remembered once the add succeeded, so a transient
                // failure is retried on the next poll.
                history.insert(item.id)
                matched.append(item)
            } catch {
                updated.lastError = String(describing: error)
            }
        }

        if history.count > Self.maxRememberedPerFeed {
            // Newest identifiers are the ones worth keeping; this is a coarse
            // trim, but the alternative is unbounded growth.
            history = Set(history.suffix(Self.maxRememberedPerFeed))
        }
        seen[feed.id] = history
        if matched.isEmpty && updated.lastError == feed.lastError {
            updated.lastError = nil
        }
        await store.update(updated)
        await store.saveHistory(seen)

        return FeedCheckResult(feedID: feed.id, matched: matched,
                               skippedAlreadySeen: skipped, error: updated.lastError)
    }
}
