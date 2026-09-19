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

/// A tracker announced to.
public struct TorrentTracker: Sendable, Identifiable, Hashable {
    public let url: String
    public let tier: Int
    public let isWorking: Bool
    public let isVerified: Bool
    public let lastError: String?
    public let peerCount: Int

    public var id: String { url }

    init(_ entry: torrentbridge.TrackerEntry) {
        url = String(entry.url)
        tier = Int(entry.tier)
        isWorking = entry.isWorking
        isVerified = entry.isVerified
        let error = String(entry.lastError)
        lastError = error.isEmpty ? nil : error
        peerCount = Int(entry.peerCount)
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
