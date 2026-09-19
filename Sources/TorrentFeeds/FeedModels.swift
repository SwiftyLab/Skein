import Foundation

/// A subscribed RSS or Atom feed.
public struct Feed: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var url: URL
    /// How often to poll. Trackers often rate-limit, so this is not tiny.
    public var refreshInterval: TimeInterval
    public var isEnabled: Bool
    /// Where matches download to; nil uses the app default.
    public var downloadDirectory: URL?
    public var rules: [FeedRule]
    public var lastChecked: Date?
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        refreshInterval: TimeInterval = 1_800,
        isEnabled: Bool = true,
        downloadDirectory: URL? = nil,
        rules: [FeedRule] = [],
        lastChecked: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.refreshInterval = refreshInterval
        self.isEnabled = isEnabled
        self.downloadDirectory = downloadDirectory
        self.rules = rules
        self.lastChecked = lastChecked
        self.lastError = lastError
    }

    public func isDue(now: Date = .now) -> Bool {
        guard isEnabled else { return false }
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= refreshInterval
    }
}

/// Decides which feed items get downloaded.
///
/// A rule with no include patterns matches everything, which is the common
/// "download the whole feed" case.
public struct FeedRule: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Item title must contain at least one of these, case-insensitively.
    public var includes: [String]
    /// Item is rejected if its title contains any of these.
    public var excludes: [String]
    /// Treat the patterns as regular expressions instead of substrings.
    public var usesRegularExpressions: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        includes: [String] = [],
        excludes: [String] = [],
        usesRegularExpressions: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.includes = includes
        self.excludes = excludes
        self.usesRegularExpressions = usesRegularExpressions
    }

    /// Whether `title` should be downloaded. Excludes win over includes, so a
    /// broad include plus a narrow exclude behaves as people expect.
    public func matches(_ title: String) -> Bool {
        guard isEnabled else { return false }
        for pattern in excludes where contains(pattern, in: title) { return false }
        guard !includes.isEmpty else { return true }
        return includes.contains { contains($0, in: title) }
    }

    private func contains(_ pattern: String, in title: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        if usesRegularExpressions {
            // An invalid expression matches nothing rather than throwing, so
            // one bad rule cannot break a whole feed.
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else { return false }
            let range = NSRange(title.startIndex..., in: title)
            return regex.firstMatch(in: title, range: range) != nil
        }
        return title.range(of: pattern, options: .caseInsensitive) != nil
    }
}

/// One entry in a feed, reduced to what auto-downloading needs.
public struct FeedItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// A magnet URI or a link to a `.torrent`.
    public let link: URL
    public let published: Date?

    public init(id: String, title: String, link: URL, published: Date?) {
        self.id = id
        self.title = title
        self.link = link
        self.published = published
    }

    public var isMagnet: Bool { link.scheme == "magnet" }
}
