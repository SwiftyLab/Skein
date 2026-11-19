import Foundation

/// A plain-text report for debugging downloads that stall, built for the user
/// to copy or share with support.
///
/// It holds what a GitHub issue can't: the interfaces and routes libtorrent saw
/// and how it classified them, which listen sockets it opened, what each one
/// did with each tracker, and the recent engine events. It contains the
/// device's IP addresses but no torrent names, and tracker URLs are cut to
/// scheme, host and port, since private trackers embed a passkey in them.
public enum DiagnosticsReport {
    /// One torrent's part of the report.
    public struct Torrent: Sendable {
        public let status: TorrentStatus
        public let trackers: [TorrentTracker]

        public init(status: TorrentStatus, trackers: [TorrentTracker]) {
            self.status = status
            self.trackers = trackers
        }
    }

    /// The whole report.
    ///
    /// - Parameters:
    ///   - header: app-level lines (version, OS, device), one per line.
    ///   - engine: ``TorrentSession/networkDiagnostics()``.
    public static func make(header: [String], engine: String, torrents: [Torrent]) -> String {
        var lines = ["# Skein diagnostics"]
        lines += header
        lines.append("")
        lines.append(engine.trimmingCharacters(in: .newlines))
        lines.append("")
        lines.append("## Torrents (\(torrents.count))")
        if torrents.isEmpty { lines.append("(none)") }
        for torrent in torrents {
            lines.append("")
            lines += describe(torrent)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One torrent, identified by a shortened info hash rather than its name.
    static func describe(_ torrent: Torrent) -> [String] {
        let status = torrent.status
        var lines = [
            "### \(status.infoHash.value.prefix(12))…",
            "state: \(status.state)\(status.isPaused ? " (paused)" : "")"
                + ", progress \(String(format: "%.1f", status.progress * 100))%"
                + ", metadata \(status.hasMetadata ? "yes" : "no")",
            "peers \(status.peerCount), seeds \(status.seedCount)"
                + ", down \(status.downloadRate) B/s, up \(status.uploadRate) B/s"
        ]
        if let error = status.errorMessage { lines.append("error: \(error)") }
        if torrent.trackers.isEmpty { lines.append("trackers: none (DHT and peer exchange only)") }
        for tracker in torrent.trackers {
            lines += describe(tracker)
        }
        return lines
    }

    /// A tracker's summary, then a line per listen socket.
    static func describe(_ tracker: TorrentTracker) -> [String] {
        let state = tracker.isWorking ? "working"
            : tracker.lastError.map { "failing: \($0)" } ?? "not yet contacted"
        var lines = ["- tier \(tracker.tier) \(tracker.redactedURL): \(state)"]
        if let message = tracker.trackerMessage { lines.append("  tracker says: \(message)") }
        for endpoint in tracker.endpoints {
            var parts = [
                "  \(endpoint.localEndpoint) v\(endpoint.protocolVersion):", endpoint.statusSummary
            ]
            if endpoint.fails > 0 { parts.append("fails \(endpoint.fails)") }
            if let seeds = endpoint.seeds { parts.append("seeds \(seeds)") }
            if let leechers = endpoint.leechers { parts.append("leechers \(leechers)") }
            if let next = endpoint.secondsToNextAnnounce { parts.append("next in \(next)s") }
            lines.append(parts.joined(separator: " "))
        }
        return lines
    }
}
