import Foundation

/// Persists feeds, their rules, and which items have already been downloaded.
public actor FeedStore {
    private let feedsURL: URL
    private let historyURL: URL
    private var cached: [Feed]?

    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return base.appendingPathComponent("Skein/Feeds", isDirectory: true)
    }

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        feedsURL = directory.appendingPathComponent("feeds.json")
        historyURL = directory.appendingPathComponent("history.json")
    }

    public func feeds() -> [Feed] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: feedsURL),
              let decoded = try? JSONDecoder().decode([Feed].self, from: data)
        else {
            cached = []
            return []
        }
        cached = decoded
        return decoded
    }

    public func add(_ feed: Feed) {
        var all = feeds()
        all.append(feed)
        write(all)
    }

    public func update(_ feed: Feed) {
        var all = feeds()
        if let index = all.firstIndex(where: { $0.id == feed.id }) {
            all[index] = feed
        } else {
            all.append(feed)
        }
        write(all)
    }

    public func remove(_ id: UUID) {
        write(feeds().filter { $0.id != id })
    }

    private func write(_ all: [Feed]) {
        cached = all
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: feedsURL, options: .atomic)
    }

    // MARK: - Download history

    public func loadHistory() -> [UUID: Set<String>] {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([UUID: Set<String>].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    public func saveHistory(_ history: [UUID: Set<String>]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }
}
