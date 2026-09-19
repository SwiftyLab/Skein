import Foundation
import TorrentBridge

/// Swift-facing entry point for the libtorrent engine.
///
/// Everything crossing the C++ boundary is converted to a native Swift type
/// here, so that no imported C++ type — none of which are `Sendable` — escapes
/// into concurrent code.
public enum TorrentEngine {

    /// The version of libtorrent this build is linked against, e.g. `"2.0.14"`.
    public static var libtorrentVersion: String {
        String(torrentbridge.libtorrentVersion())
    }

    /// The version of OpenSSL this build is linked against, e.g. `"3.5.8"`.
    public static var opensslVersion: String {
        String(torrentbridge.opensslVersion())
    }

    /// Whether libtorrent was compiled with OpenSSL support. When false there
    /// are no HTTPS trackers and no SSL torrents.
    public static var supportsSSL: Bool {
        torrentbridge.libtorrentHasSSL()
    }

    /// Builds a trackerless `.torrent` describing `contentURL`.
    ///
    /// Peers must be introduced directly with ``TorrentSession/addPeer(_:host:port:)``,
    /// since the result announces to nothing.
    public static func createTorrentFile(
        describing contentURL: URL,
        writingTo outputURL: URL,
        pieceLength: Int = 32_768
    ) throws {
        let result = torrentbridge.createTorrentFile(
            std.string(contentURL.path), std.string(outputURL.path), Int32(pieceLength))
        guard result.ok else { throw TorrentError.engine(String(result.message)) }
    }

    /// Reads the display name out of a `.torrent` file.
    ///
    /// libtorrent throws on malformed input. The C++ facade catches that and
    /// reports it in its return value, which this surfaces as a thrown Swift
    /// error — a C++ exception reaching Swift would abort the process.
    public static func torrentName(atPath path: String) throws -> String {
        var name = std.string()
        let result = torrentbridge.torrentNameFromFile(std.string(path), &name)
        guard result.ok else {
            throw TorrentError.engine(String(result.message))
        }
        return String(name)
    }
}
