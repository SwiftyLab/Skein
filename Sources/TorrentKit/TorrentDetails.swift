import Foundation
import TorrentBridge

/// How much a file matters, mirroring libtorrent's scale.
public enum FilePriority: Int, Sendable, CaseIterable, Identifiable {
    /// Not downloaded at all.
    case skip = 0
    case low = 1
    case normal = 4
    case high = 7

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .skip: return "Don't Download"
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }

    init(_ raw: torrentbridge.Priority) {
        switch raw {
        case .skip: self = .skip
        case .low: self = .low
        case .high: self = .high
        default: self = .normal
        }
    }

    var bridgeValue: torrentbridge.Priority {
        switch self {
        case .skip: return .skip
        case .low: return .low
        case .normal: return .normal
        case .high: return .high
        }
    }
}

/// One file inside a torrent.
public struct TorrentFile: Sendable, Identifiable, Hashable {
    public let index: Int
    public let path: String
    public let size: Int64
    public let downloaded: Int64
    public let priority: FilePriority

    public var id: Int { index }
    public var name: String { (path as NSString).lastPathComponent }
    public var progress: Double {
        size > 0 ? min(1, Double(downloaded) / Double(size)) : 0
    }

    init(_ entry: torrentbridge.FileEntry) {
        index = Int(entry.index)
        path = String(entry.path)
        size = entry.size
        downloaded = entry.downloaded
        priority = FilePriority(entry.priority)
    }
}

/// A connected peer.
public struct TorrentPeer: Sendable, Identifiable, Hashable {
    public let address: String
    public let port: Int
    public let client: String
    public let downloadRate: Int
    public let uploadRate: Int
    public let progress: Double
    public let isSeed: Bool
    public let isEncrypted: Bool

    public var id: String { "\(address):\(port)" }

    init(_ entry: torrentbridge.PeerEntry) {
        address = String(entry.address)
        port = Int(entry.port)
        client = String(entry.client)
        downloadRate = Int(entry.downloadRate)
        uploadRate = Int(entry.uploadRate)
        progress = Double(entry.progress)
        isSeed = entry.isSeed
        isEncrypted = entry.isEncrypted
    }
}

/// One listen socket's dealings with one tracker.
///
/// libtorrent announces to each tracker separately from every listen socket,
/// and opens one per interface address — on iOS that includes loopback,
/// link-local, cellular, tunnels and many IPv6 addresses. Most are rightly
/// skipped for any one tracker, so these matter mainly for diagnostics;
/// ``TorrentTracker`` summarises them.
public struct TrackerEndpoint: Sendable, Identifiable, Hashable {
    /// The listen socket's address, e.g. "192.168.1.5:6881".
    public let localEndpoint: String
    /// BitTorrent protocol version announced: 1, or 2 for v2 and hybrid torrents.
    public let protocolVersion: Int
    public let isEnabled: Bool
    /// An announce is in flight.
    public let isUpdating: Bool
    /// The tracker has accepted an announce from this socket.
    public let hasAnnounced: Bool
    /// libtorrent did not announce from this socket because it cannot reach the
    /// tracker's address, e.g. an IPv6 socket and an IPv4-only tracker.
    public let isSkipped: Bool
    public let lastError: String?
    /// Free text the tracker sent back, usually a warning.
    public let trackerMessage: String?
    /// Consecutive failures.
    public let fails: Int
    /// Seeds and leechers the tracker reported, when it did.
    public let seeds: Int?
    public let leechers: Int?
    /// Seconds until the next announce, when one is scheduled.
    public let secondsToNextAnnounce: Int?

    public var id: String { "\(localEndpoint) v\(protocolVersion)" }

    /// The last announce from this socket succeeded.
    public var isWorking: Bool { hasAnnounced && lastError == nil }

    /// A short status, e.g. "announced" or "skipped (cannot route)".
    public var statusSummary: String {
        if !isEnabled { return "disabled" }
        if isSkipped { return "skipped (cannot route)" }
        if isWorking { return "announced" }
        if let lastError { return "error: \(lastError)" }
        if isUpdating { return "announcing" }
        return "pending"
    }

    init(
        localEndpoint: String, protocolVersion: Int = 1, isEnabled: Bool = true,
        isUpdating: Bool = false, hasAnnounced: Bool = false, isSkipped: Bool = false,
        lastError: String? = nil, trackerMessage: String? = nil, fails: Int = 0,
        seeds: Int? = nil, leechers: Int? = nil, secondsToNextAnnounce: Int? = nil
    ) {
        self.localEndpoint = localEndpoint
        self.protocolVersion = protocolVersion
        self.isEnabled = isEnabled
        self.isUpdating = isUpdating
        self.hasAnnounced = hasAnnounced
        self.isSkipped = isSkipped
        self.lastError = lastError
        self.trackerMessage = trackerMessage
        self.fails = fails
        self.seeds = seeds
        self.leechers = leechers
        self.secondsToNextAnnounce = secondsToNextAnnounce
    }

    init(_ entry: torrentbridge.TrackerEndpointEntry) {
        let error = String(entry.lastError)
        let message = String(entry.trackerMessage)
        self.init(
            localEndpoint: String(entry.localEndpoint),
            protocolVersion: Int(entry.protocolVersion),
            isEnabled: entry.isEnabled,
            isUpdating: entry.isUpdating,
            hasAnnounced: entry.hasAnnounced,
            isSkipped: entry.isSkipped,
            lastError: error.isEmpty ? nil : error,
            trackerMessage: message.isEmpty ? nil : message,
            fails: Int(entry.fails),
            seeds: entry.scrapeComplete >= 0 ? Int(entry.scrapeComplete) : nil,
            leechers: entry.scrapeIncomplete >= 0 ? Int(entry.scrapeIncomplete) : nil,
            secondsToNextAnnounce: entry.secondsToNextAnnounce >= 0
                ? Int(entry.secondsToNextAnnounce) : nil)
    }
}

/// A tracker announced to.
public struct TorrentTracker: Sendable, Identifiable, Hashable {
    /// Shown when every listen socket was skipped, in place of libtorrent's
    /// "skipping tracker announce (unreachable)", which reads like a network
    /// fault rather than "no interface could reach this address".
    public static let unreachableMessage =
        "Unreachable: no network interface can reach this tracker"

    public let url: String
    public let tier: Int
    public let isVerified: Bool
    /// One row per listen socket and protocol version.
    public let endpoints: [TrackerEndpoint]

    public var id: String { url }

    /// Any listen socket's last announce succeeded.
    public var isWorking: Bool { endpoints.contains(where: \.isWorking) }

    /// The error worth showing, or nil when the tracker works or has not
    /// answered yet.
    ///
    /// Skipped sockets are expected — most of a phone's interfaces cannot reach
    /// any given tracker — so they never hide a real error from another socket,
    /// and only count when every socket was skipped.
    public var lastError: String? {
        guard !isWorking else { return nil }
        if let real = endpoints.first(where: { $0.lastError != nil && !$0.isSkipped }) {
            return real.lastError
        }
        if !endpoints.isEmpty, endpoints.allSatisfy(\.isSkipped) {
            return Self.unreachableMessage
        }
        return nil
    }

    /// A warning the tracker sent, if any.
    public var trackerMessage: String? {
        endpoints.lazy.compactMap(\.trackerMessage).first
    }

    /// The most seeds any socket heard about.
    public var peerCount: Int { endpoints.compactMap(\.seeds).max() ?? 0 }

    /// The URL with anything that might identify the user removed. Private
    /// trackers put a passkey in the path or query, so only the scheme, host
    /// and port survive; for sharing in diagnostics.
    public var redactedURL: String {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme, let host = components.host
        else { return "(unparseable tracker URL)" }
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path == "/announce" && components.query == nil
            ? "/announce" : "/…"
        return "\(scheme)://\(host)\(port)\(path)"
    }

    init(url: String, tier: Int = 0, isVerified: Bool = false, endpoints: [TrackerEndpoint]) {
        self.url = url
        self.tier = tier
        self.isVerified = isVerified
        self.endpoints = endpoints
    }

    init(_ entry: torrentbridge.TrackerEntry) {
        self.init(
            url: String(entry.url),
            tier: Int(entry.tier),
            isVerified: entry.isVerified,
            endpoints: entry.endpoints.map(TrackerEndpoint.init))
    }
}

/// Where a file sits within a torrent, and how the torrent is carved into
/// pieces — enough to turn a byte range into the pieces that cover it.
public struct FileLocation: Sendable, Hashable {
    /// Byte offset of the file within the torrent's overall stream.
    public let offset: Int64
    public let size: Int64
    public let pieceLength: Int
    public let firstPiece: Int
    public let lastPiece: Int
    /// Absolute path the file is being written to.
    public let path: String

    public init(
        offset: Int64, size: Int64, pieceLength: Int,
        firstPiece: Int, lastPiece: Int, path: String
    ) {
        self.offset = offset
        self.size = size
        self.pieceLength = pieceLength
        self.firstPiece = firstPiece
        self.lastPiece = lastPiece
        self.path = path
    }

    init(_ raw: torrentbridge.FileLocation) {
        offset = raw.offset
        size = raw.size
        pieceLength = Int(raw.pieceLength)
        firstPiece = Int(raw.firstPiece)
        lastPiece = Int(raw.lastPiece)
        path = String(raw.path)
    }

    /// The pieces covering `range`, expressed as byte offsets within the file.
    public func pieces(covering range: Range<Int64>) -> ClosedRange<Int> {
        let start = offset + max(0, range.lowerBound)
        let end = offset + min(size, range.upperBound) - 1
        guard end >= start else { return firstPiece...firstPiece }
        return Int(start / Int64(pieceLength))...Int(end / Int64(pieceLength))
    }
}
