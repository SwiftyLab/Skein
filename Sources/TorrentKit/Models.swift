import Foundation
import TorrentBridge

/// Stable identifier for a torrent: the hex-encoded info hash.
public struct InfoHash: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String { value }
    /// First eight characters, for logs and compact UI.
    public var short: String { String(value.prefix(8)) }
}

/// What a torrent is currently doing.
public enum TorrentState: Sendable, Hashable {
    case checkingResumeData
    case checkingFiles
    case downloadingMetadata
    case downloading
    case finished
    case seeding
    case unknown

    init(_ raw: torrentbridge.TorrentState) {
        switch raw {
        case .checkingResumeData: self = .checkingResumeData
        case .checkingFiles: self = .checkingFiles
        case .downloadingMetadata: self = .downloadingMetadata
        case .downloading: self = .downloading
        case .finished: self = .finished
        case .seeding: self = .seeding
        default: self = .unknown
        }
    }
}

/// An immutable view of one torrent at one instant.
///
/// Converted from the C++ aggregate at the boundary so that no imported C++
/// type — none of which are `Sendable` — escapes into concurrent code.
public struct TorrentStatus: Sendable, Identifiable, Hashable {
    public let infoHash: InfoHash
    public let name: String
    public let savePath: String
    public let state: TorrentState
    public let progress: Double
    public let totalWanted: Int64
    public let totalWantedDone: Int64
    public let totalDownloaded: Int64
    public let totalUploaded: Int64
    public let downloadRate: Int
    public let uploadRate: Int
    public let peerCount: Int
    public let seedCount: Int
    public let isPaused: Bool
    /// Pieces are being fetched in order, which streaming depends on.
    public let isSequential: Bool
    public let isFinished: Bool
    public let isSeeding: Bool
    public let hasMetadata: Bool
    public let errorMessage: String?

    public var id: InfoHash { infoHash }

    init(_ snapshot: torrentbridge.TorrentSnapshot) {
        infoHash = InfoHash(String(snapshot.infoHash))
        name = String(snapshot.name)
        savePath = String(snapshot.savePath)
        state = TorrentState(snapshot.state)
        progress = Double(snapshot.progress)
        totalWanted = snapshot.totalWanted
        totalWantedDone = snapshot.totalWantedDone
        totalDownloaded = snapshot.totalDownloaded
        totalUploaded = snapshot.totalUploaded
        downloadRate = Int(snapshot.downloadRate)
        uploadRate = Int(snapshot.uploadRate)
        peerCount = Int(snapshot.numPeers)
        seedCount = Int(snapshot.numSeeds)
        isPaused = snapshot.isPaused
        isSequential = snapshot.isSequential
        isFinished = snapshot.isFinished
        isSeeding = snapshot.isSeeding
        hasMetadata = snapshot.hasMetadata
        let error = String(snapshot.errorMessage)
        errorMessage = error.isEmpty ? nil : error
    }

    /// Seconds until completion, or nil when stalled or already done.
    public var estimatedTimeRemaining: TimeInterval? {
        guard downloadRate > 0, totalWanted > totalWantedDone else { return nil }
        return TimeInterval(totalWanted - totalWantedDone) / TimeInterval(downloadRate)
    }
}

/// Something that happened in the session.
public enum SessionEvent: Sendable {
    case torrentAdded(TorrentStatus)
    case torrentRemoved(InfoHash)
    case torrentFinished(InfoHash)
    case torrentPaused(InfoHash)
    case torrentResumed(InfoHash)
    case torrentChecked(InfoHash)
    case metadataReceived(InfoHash)
    case statusUpdated(TorrentStatus)
    case torrentFailed(InfoHash, String)
    case trackerFailed(InfoHash, String)
    case resumeDataSaved(InfoHash, Data)
    case resumeDataFailed(InfoHash, String)
    /// The files finished moving; the payload is the new save path.
    case storageMoved(InfoHash, String)
    case storageMoveFailed(InfoHash, String)
    case contentRenamed(InfoHash, String)
    case contentRenameFailed(InfoHash, String)
    case sessionStopped
    /// An alert the bridge does not map. Carried rather than dropped so nothing
    /// disappears silently.
    case other(String)

    init?(_ alert: torrentbridge.Alert) {
        let hash = InfoHash(String(alert.infoHash))
        let message = String(alert.message)
        switch alert.kind {
        case .torrentAdded:
            guard alert.hasSnapshot else { return nil }
            self = .torrentAdded(TorrentStatus(alert.snapshot))
        case .stateUpdate:
            guard alert.hasSnapshot else { return nil }
            self = .statusUpdated(TorrentStatus(alert.snapshot))
        case .torrentRemoved: self = .torrentRemoved(hash)
        case .torrentFinished: self = .torrentFinished(hash)
        case .torrentPaused: self = .torrentPaused(hash)
        case .torrentResumed: self = .torrentResumed(hash)
        case .torrentChecked: self = .torrentChecked(hash)
        case .metadataReceived: self = .metadataReceived(hash)
        case .torrentErrored: self = .torrentFailed(hash, message)
        case .trackerError: self = .trackerFailed(hash, message)
        case .resumeDataSaved:
            // Copied byte-wise; resume data is binary and must not pass through
            // a Swift String.
            self = .resumeDataSaved(hash, Data(alert.resumeData))
        case .resumeDataFailed: self = .resumeDataFailed(hash, message)
        case .storageMoved: self = .storageMoved(hash, message)
        case .storageMoveFailed: self = .storageMoveFailed(hash, message)
        case .contentRenamed: self = .contentRenamed(hash, message)
        case .contentRenameFailed: self = .contentRenameFailed(hash, message)
        case .sessionShutdown: self = .sessionStopped
        default: self = .other(message)
        }
    }
}

/// Errors surfaced from the C++ engine.
public enum TorrentError: Error, Equatable, Sendable {
    /// libtorrent reported a failure; the payload is its message.
    case engine(String)
    /// The session could not be started.
    case sessionStartFailed
    /// An operation was attempted after the session was stopped.
    case sessionStopped
}

/// How aggressively to use BitTorrent message-stream encryption.
///
/// Encryption here obfuscates the peer wire protocol; it defeats naive
/// traffic shaping but is not a privacy guarantee.
public enum EncryptionPolicy: Int, Sendable, CaseIterable, Identifiable {
    /// Accept and prefer plaintext.
    case disabled = 0
    /// Offer encryption, fall back to plaintext.
    case enabled = 1
    /// Refuse unencrypted peers entirely, at the cost of reaching fewer of them.
    case required = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .disabled: return "Off"
        case .enabled: return "Prefer encryption"
        case .required: return "Require encryption"
        }
    }

    var bridgeValue: torrentbridge.EncryptionPolicy {
        switch self {
        case .disabled: return .disabled
        case .enabled: return .enabled
        case .required: return .required
        }
    }
}

public enum ProxyKind: Int, Sendable, CaseIterable, Identifiable {
    case none = 0
    case socks4 = 1
    case socks5 = 2
    case http = 3

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .none: return "None"
        case .socks4: return "SOCKS4"
        case .socks5: return "SOCKS5"
        case .http: return "HTTP"
        }
    }

    var bridgeValue: torrentbridge.ProxyKind {
        switch self {
        case .none: return .none
        case .socks4: return .socks4
        case .socks5: return .socks5
        case .http: return .http
        }
    }
}

public struct ProxyConfiguration: Sendable, Equatable {
    public var kind: ProxyKind
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    /// Route peer traffic through the proxy too, not just tracker requests.
    /// Without this the proxy hides announces but not who you talk to.
    public var proxiesPeerConnections: Bool
    /// Resolve hostnames at the proxy so DNS lookups do not leak locally.
    public var proxiesHostnames: Bool

    public init(
        kind: ProxyKind = .none,
        host: String = "",
        port: Int = 1080,
        username: String = "",
        password: String = "",
        proxiesPeerConnections: Bool = true,
        proxiesHostnames: Bool = true
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.proxiesPeerConnections = proxiesPeerConnections
        self.proxiesHostnames = proxiesHostnames
    }

    func makeBridgeConfig() -> torrentbridge.ProxyConfig {
        var config = torrentbridge.ProxyConfig()
        config.kind = kind.bridgeValue
        config.host = std.string(host)
        config.port = Int32(port)
        config.username = std.string(username)
        config.password = std.string(password)
        config.proxyPeerConnections = proxiesPeerConnections
        config.proxyHostnames = proxiesHostnames
        return config
    }
}

/// Settings applied when the session starts.
public struct SessionConfiguration: Sendable {
    public var listenInterfaces: String
    public var userAgent: String
    public var isDHTEnabled: Bool
    public var isLocalDiscoveryEnabled: Bool
    public var isUPnPEnabled: Bool
    public var isNATPMPEnabled: Bool
    /// Bytes per second; zero means unlimited.
    public var downloadRateLimit: Int
    public var uploadRateLimit: Int
    /// libtorrent 2.x defaults to mmap-based disk I/O, the usual suspect for
    /// memory trouble on iOS. Defaults to true there, false on macOS.
    public var usesPOSIXDiskIO: Bool
    /// Peer exchange. Cannot be changed once the session is running, because it
    /// is a libtorrent plugin rather than a setting.
    public var isPEXEnabled: Bool
    public var encryption: EncryptionPolicy
    public var proxy: ProxyConfiguration
    /// Caps on simultaneously active torrents; -1 keeps libtorrent's defaults.
    public var maxActiveDownloads: Int
    public var maxActiveSeeds: Int
    public var maxConnections: Int

    public init(
        listenInterfaces: String = "0.0.0.0:6881,[::]:6881",
        userAgent: String = "Skein/0.1",
        isDHTEnabled: Bool = true,
        isLocalDiscoveryEnabled: Bool = true,
        isUPnPEnabled: Bool = true,
        isNATPMPEnabled: Bool = true,
        downloadRateLimit: Int = 0,
        uploadRateLimit: Int = 0,
        usesPOSIXDiskIO: Bool = SessionConfiguration.defaultUsesPOSIXDiskIO,
        isPEXEnabled: Bool = true,
        encryption: EncryptionPolicy = .enabled,
        proxy: ProxyConfiguration = ProxyConfiguration(),
        maxActiveDownloads: Int = -1,
        maxActiveSeeds: Int = -1,
        maxConnections: Int = -1
    ) {
        self.listenInterfaces = listenInterfaces
        self.userAgent = userAgent
        self.isDHTEnabled = isDHTEnabled
        self.isLocalDiscoveryEnabled = isLocalDiscoveryEnabled
        self.isUPnPEnabled = isUPnPEnabled
        self.isNATPMPEnabled = isNATPMPEnabled
        self.downloadRateLimit = downloadRateLimit
        self.uploadRateLimit = uploadRateLimit
        self.usesPOSIXDiskIO = usesPOSIXDiskIO
        self.isPEXEnabled = isPEXEnabled
        self.encryption = encryption
        self.proxy = proxy
        self.maxActiveDownloads = maxActiveDownloads
        self.maxActiveSeeds = maxActiveSeeds
        self.maxConnections = maxConnections
    }

    public static var defaultUsesPOSIXDiskIO: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// A session that talks to nobody: no DHT, no local discovery, no port
    /// mapping, and an ephemeral port. Useful for tests.
    public static var offline: SessionConfiguration {
        SessionConfiguration(
            listenInterfaces: "127.0.0.1:0",
            isDHTEnabled: false,
            isLocalDiscoveryEnabled: false,
            isUPnPEnabled: false,
            isNATPMPEnabled: false,
            isPEXEnabled: false
        )
    }

    func makeBridgeConfig() -> torrentbridge.SessionConfig {
        var config = torrentbridge.SessionConfig()
        config.listenInterfaces = std.string(listenInterfaces)
        config.userAgent = std.string(userAgent)
        config.enableDHT = isDHTEnabled
        config.enableLSD = isLocalDiscoveryEnabled
        config.enableUPnP = isUPnPEnabled
        config.enableNATPMP = isNATPMPEnabled
        config.downloadRateLimit = Int32(downloadRateLimit)
        config.uploadRateLimit = Int32(uploadRateLimit)
        config.usePosixDiskIO = usesPOSIXDiskIO
        config.enablePEX = isPEXEnabled
        config.encryption = encryption.bridgeValue
        config.proxy = proxy.makeBridgeConfig()
        config.maxActiveDownloads = Int32(maxActiveDownloads)
        config.maxActiveSeeds = Int32(maxActiveSeeds)
        config.maxConnections = Int32(maxConnections)
        return config
    }
}
