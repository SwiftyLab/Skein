import Foundation
import FeedKit

/// Turns RSS or Atom XML into ``FeedItem``s.
///
/// Torrent feeds vary: some put a magnet in the link, some in the GUID, some
/// only in an enclosure. This looks in all three rather than assuming one.
public enum FeedDocumentParser {

    public enum ParseError: Error, Equatable, Sendable {
        case unsupportedFormat
        case malformed(String)
    }

    public static func parse(_ data: Data) throws -> (title: String?, items: [FeedItem]) {
        let feed: FeedKit.Feed
        do {
            feed = try FeedKit.Feed(data: data)
        } catch {
            throw ParseError.malformed(String(describing: error))
        }

        switch feed {
        case .rss(let rss):
            return (rss.channel?.title, (rss.channel?.items ?? []).compactMap(item(from:)))
        case .atom(let atom):
            return (atom.title?.text, (atom.entries ?? []).compactMap(item(from:)))
        default:
            throw ParseError.unsupportedFormat
        }
    }

    private static func item(from entry: RSSFeedItem) -> FeedItem? {
        let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled"
        // Preference order: an explicit enclosure, then the link, then the GUID
        // — some trackers only ever put the magnet in the GUID.
        let candidates = [
            entry.enclosure?.attributes?.url,
            entry.link,
            entry.guid?.text,
        ]
        guard let link = firstUsableLink(in: candidates) else { return nil }
        return FeedItem(
            id: entry.guid?.text ?? link.absoluteString,
            title: title,
            link: link,
            published: entry.pubDate)
    }

    private static func item(from entry: AtomFeedEntry) -> FeedItem? {
        let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled"
        let candidates = (entry.links ?? []).map { $0.attributes?.href } + [entry.id]
        guard let link = firstUsableLink(in: candidates) else { return nil }
        return FeedItem(
            id: entry.id ?? link.absoluteString,
            title: title,
            link: link,
            published: entry.updated ?? entry.published)
    }

    /// Accepts magnet URIs and http(s) links; anything else is not something we
    /// could hand to the engine.
    private static func firstUsableLink(in candidates: [String?]) -> URL? {
        for case let raw? in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed) else { continue }
            if url.scheme == "magnet" { return url }
            if url.scheme == "http" || url.scheme == "https" { return url }
        }
        return nil
    }
}
