#pragma once

#include <cstdint>
#include <string>
#include <vector>

// <swift/bridging> ships with the toolchain but is not on SwiftPM's default
// C++ include path, and its location differs between the Xcode and swift.org
// toolchains. Define the one macro we need ourselves when it is unavailable,
// rather than hardcoding a toolchain path.
#if __has_include(<swift/bridging>)
#include <swift/bridging>
#else
#define _TB_STRINGIFY_IMPL(x) #x
#define _TB_STRINGIFY(x) _TB_STRINGIFY_IMPL(x)
#define SWIFT_SHARED_REFERENCE(_retain, _release)                              \
    __attribute__((swift_attr("import_reference")))                            \
    __attribute__((swift_attr(_TB_STRINGIFY(retain:_retain))))                 \
    __attribute__((swift_attr(_TB_STRINGIFY(release:_release))))
#define SWIFT_RETURNS_RETAINED __attribute__((swift_attr("returns_retained")))
#endif

// Narrow C++ facade over libtorrent, imported directly by Swift via C++ interop.
//
// Three rules govern everything in this header:
//
//  1. Swift cannot catch C++ exceptions. If one reaches Swift the process
//     terminates with a fatal error and no Swift traceback. Every function
//     defined in TorrentBridge.cpp therefore wraps its body in
//     `try { ... } catch (...) { ... }` and reports failure in its return value.
//
//  2. Only Swift-importable constructs appear here: plain aggregates,
//     std::string, std::vector of plain aggregates, and `enum class ... : int`.
//     No libtorrent type, no Boost type, and no template of our own crosses
//     this boundary.
//
//  3. No C++ calls back into Swift. libtorrent's natural hook,
//     `session::set_alert_notify`, takes a std::function, and C++ -> Swift
//     callbacks are not a supported interop pattern. Swift pulls instead, via
//     the blocking `waitAndDrainAlerts`.

namespace torrentbridge {

/// Named so Swift can spell it: `std::vector<T>` imports as a two-parameter
/// generic (element plus allocator), which is awkward to write at a call site.
using ByteBuffer = std::vector<std::uint8_t>;
using StringList = std::vector<std::string>;

/// Outcome of a facade call that can fail. `ok == false` means the underlying
/// libtorrent call threw and `message` carries what it said.
struct Result {
    bool ok;
    std::string message;
};

/// Outcome of adding a torrent, carrying the resulting info hash on success.
struct AddResult {
    bool ok;
    std::string message;
    std::string infoHash;
};

/// Mirrors libtorrent's `torrent_status::state_t`, plus an `unknown` fallback so
/// a future libtorrent value cannot produce a garbage Swift enum.
enum class TorrentState : int {
    unknown = 0,
    checkingResumeData = 1,
    checkingFiles = 2,
    downloadingMetadata = 3,
    downloading = 4,
    finished = 5,
    seeding = 6,
};

/// Which libtorrent alert an `Alert` represents. Only the subset the client
/// acts on is mapped; everything else arrives as `unknown` with its message
/// preserved, so nothing is silently dropped.
enum class AlertKind : int {
    unknown = 0,
    torrentAdded,
    torrentRemoved,
    torrentFinished,
    torrentPaused,
    torrentResumed,
    torrentChecked,
    torrentErrored,
    metadataReceived,
    stateUpdate,
    trackerError,
    resumeDataSaved,
    resumeDataFailed,
    storageMoved,
    storageMoveFailed,
    contentRenamed,
    contentRenameFailed,
    sessionShutdown,
};

/// An immutable view of one torrent at one instant.
struct TorrentSnapshot {
    std::string infoHash;
    std::string name;
    std::string savePath;
    TorrentState state;
    float progress;               // 0...1
    std::int64_t totalWanted;     // bytes selected for download
    std::int64_t totalWantedDone; // bytes of those already verified
    std::int64_t totalDownloaded;
    std::int64_t totalUploaded;
    std::int32_t downloadRate;    // bytes/second
    std::int32_t uploadRate;
    std::int32_t numPeers;
    std::int32_t numSeeds;
    bool isPaused;
    bool isSequential;
    bool isFinished;
    bool isSeeding;
    bool hasMetadata;
    std::string errorMessage;
};

/// Download priority for a file or piece. Mirrors libtorrent's scale, where
/// zero means "do not download".
enum class Priority : int {
    skip = 0,
    low = 1,
    normal = 4,
    high = 7,
};

/// One file within a torrent.
struct FileEntry {
    std::int32_t index;
    std::string path;
    std::int64_t size;
    std::int64_t downloaded;
    Priority priority;
};

/// Where a file sits within the torrent, and how the torrent is carved into
/// pieces. Enough to map a byte range onto the pieces that cover it.
struct FileLocation {
    std::int64_t offset;     // byte offset of the file within the torrent
    std::int64_t size;
    std::int32_t pieceLength;
    std::int32_t firstPiece;
    std::int32_t lastPiece;
    std::string path;        // absolute path on disk
};

/// One connected peer.
struct PeerEntry {
    std::string address;
    std::int32_t port;
    std::string client;
    std::int32_t downloadRate;
    std::int32_t uploadRate;
    float progress;
    bool isSeed;
    bool isEncrypted;
};

/// One tracker for a torrent.
struct TrackerEntry {
    std::string url;
    std::int32_t tier;
    bool isWorking;
    bool isVerified;
    std::string lastError;
    std::int32_t peerCount;
};

/// One event drained from libtorrent's alert queue.
struct Alert {
    AlertKind kind;
    std::string infoHash;
    std::string message;
    /// Populated for `torrentAdded` and `stateUpdate`; `hasSnapshot` says so.
    TorrentSnapshot snapshot;
    bool hasSnapshot;
    /// Populated for `resumeDataSaved`. A byte vector rather than a
    /// std::string: resume data is binary, and routing it through a Swift
    /// String would corrupt any non-UTF-8 sequence.
    ByteBuffer resumeData;
};

/// How aggressively to use BitTorrent message-stream encryption.
enum class EncryptionPolicy : int {
    /// Accept and prefer plaintext.
    disabled = 0,
    /// Offer encryption, fall back to plaintext.
    enabled = 1,
    /// Refuse unencrypted peers entirely.
    required = 2,
};

enum class ProxyKind : int {
    none = 0,
    socks4 = 1,
    socks5 = 2,
    http = 3,
};

/// Proxy settings. `kind == none` disables proxying and ignores the rest.
struct ProxyConfig {
    ProxyKind kind;
    std::string host;
    std::int32_t port;
    std::string username;
    std::string password;
    /// Route peer connections through the proxy, not just trackers.
    bool proxyPeerConnections;
    /// Resolve tracker hostnames at the proxy, so DNS does not leak.
    bool proxyHostnames;
};

/// Settings applied when the session starts.
struct SessionConfig {
    /// libtorrent's `listen_interfaces`, e.g. "0.0.0.0:6881,[::]:6881".
    std::string listenInterfaces;
    std::string userAgent;
    bool enableDHT;
    bool enableLSD;
    bool enableUPnP;
    bool enableNATPMP;
    /// 0 means unlimited.
    std::int32_t downloadRateLimit;
    std::int32_t uploadRateLimit;
    /// libtorrent 2.x defaults to mmap-based disk I/O, which is the usual
    /// suspect for memory trouble on iOS. Setting this selects
    /// `posix_disk_io_constructor` instead.
    bool usePosixDiskIO;
    /// Peer exchange. Off for private torrents regardless of this.
    bool enablePEX;
    EncryptionPolicy encryption;
    ProxyConfig proxy;
    /// Active torrent caps; -1 leaves libtorrent's defaults alone.
    std::int32_t maxActiveDownloads;
    std::int32_t maxActiveSeeds;
    std::int32_t maxConnections;
};

class Session;
} // namespace torrentbridge

// Declared at global scope on purpose: Swift resolves the names in a
// SWIFT_SHARED_REFERENCE attribute against the global scope, so a retain/release
// pair declared inside the namespace is not found.
void torrentBridgeSessionRetain(torrentbridge::Session *session);
void torrentBridgeSessionRelease(torrentbridge::Session *session);

namespace torrentbridge {

/// Owns an `lt::session`. Declared as a Swift shared reference so Swift manages
/// its lifetime with ARC through the retain/release pair above.
///
/// Thread safety: libtorrent's session is internally synchronised, and the only
/// blocking call here is `waitAndDrainAlerts`, which Swift runs on a dedicated
/// thread while other methods are called from an actor. That is why the Swift
/// wrapper can be `@unchecked Sendable`.
class SWIFT_SHARED_REFERENCE(torrentBridgeSessionRetain,
                             torrentBridgeSessionRelease) Session {
public:
    ~Session();

    Session(const Session &) = delete;
    Session &operator=(const Session &) = delete;

    /// Blocks up to `timeoutMs` for alerts, then drains everything queued.
    /// Returns empty on timeout. Must be called from a dedicated thread, never
    /// one of Swift's cooperative pool threads.
    std::vector<Alert> waitAndDrainAlerts(std::int32_t timeoutMs);

    AddResult addMagnet(const std::string &uri, const std::string &savePath);
    AddResult addTorrentFile(const std::string &path, const std::string &savePath);
    /// `resumeData` is a buffer previously delivered by a `resumeDataSaved` alert.
    AddResult addTorrentFileWithResume(const std::string &path,
                                       const std::string &savePath,
                                       const ByteBuffer &resumeData);

    /// Re-adds a torrent purely from saved resume data. Resume data saved with
    /// the info dictionary carries the metadata too, so this restores both
    /// file-added and magnet-added torrents without needing the original
    /// .torrent or magnet URI.
    AddResult addFromResumeData(const ByteBuffer &resumeData, const std::string &savePath);

    Result removeTorrent(const std::string &infoHash, bool deleteFiles);
    Result pauseTorrent(const std::string &infoHash);
    Result resumeTorrent(const std::string &infoHash);
    Result recheckTorrent(const std::string &infoHash);
    Result reannounceTorrent(const std::string &infoHash);
    /// Moves the files and updates the save path. Asynchronous: the caller
    /// learns the outcome from a `storageMoved` or `storageMoveFailed` alert,
    /// and must keep any sandbox access to the destination open until then.
    Result moveStorage(const std::string &infoHash, const std::string &newPath);

    /// Renames the torrent's content on disk — the containing folder for a
    /// multi-file torrent, or the file itself for a single-file one.
    ///
    /// This renames real files rather than just a label: libtorrent has no way
    /// to change a torrent's display name on a live handle, because that name
    /// comes from the metadata the info hash is computed over.
    Result renameContent(const std::string &infoHash, const std::string &newName);

    /// Per-torrent rate limits in bytes per second; zero means unlimited.
    Result setTorrentLimits(const std::string &infoHash, std::int32_t downloadLimit,
                            std::int32_t uploadLimit);
    /// Serves pieces in order, for streaming playback.
    Result setSequentialDownload(const std::string &infoHash, bool sequential);

    /// Raises the priority of the pieces at both ends of every wanted file.
    ///
    /// Sequential download alone is not enough to start playback: most
    /// containers keep an index at the end of the file — MP4's moov atom, AVI's
    /// index, Matroska cues — so a player cannot open the file until the tail
    /// has arrived as well as the head. Requires metadata, so it has no effect
    /// on a magnet link until peers have supplied it.
    Result setFirstLastPiecePriority(const std::string &infoHash, bool enabled);

    /// Whether the ends of the first wanted file are already prioritised.
    /// Inferred from piece priorities rather than stored, so it survives a
    /// relaunch and reflects what libtorrent is actually doing.
    bool hasFirstLastPiecePriority(const std::string &infoHash);

    std::vector<FileEntry> listFiles(const std::string &infoHash);
    Result setFilePriority(const std::string &infoHash, std::int32_t fileIndex,
                           Priority priority);
    std::vector<PeerEntry> listPeers(const std::string &infoHash);
    std::vector<TrackerEntry> listTrackers(const std::string &infoHash);

    /// Which pieces are complete, one byte per piece (1 = have). A byte vector
    /// rather than std::vector<bool>, which is bit-packed and whose elements
    /// import into Swift as proxy references instead of Bool.
    ByteBuffer pieceAvailability(const std::string &infoHash);

    /// Queue position; lower runs first. -1 means the torrent is not queued.
    Result setQueuePosition(const std::string &infoHash, std::int32_t position);

    // MARK: Streaming
    //
    // libtorrent's docs are explicit that deadline-based time-critical piece
    // management, not sequential_download, is the mechanism intended for
    // playback: sequential mode lets one slow peer holding an early piece block
    // faster peers, whereas deadlines actively reorder requests across peers.

    /// Marks a piece as needed within `deadlineMs`, raising its priority.
    Result setPieceDeadline(const std::string &infoHash, std::int32_t pieceIndex,
                            std::int32_t deadlineMs);
    /// Drops every deadline, returning to normal rarest-first picking.
    Result clearPieceDeadlines(const std::string &infoHash);

    /// Where a file sits in the torrent's byte stream, so a byte range can be
    /// turned into the pieces that cover it. Returns -1 values if unknown.
    FileLocation locateFile(const std::string &infoHash, std::int32_t fileIndex);

    /// Asks for a `stateUpdate` alert covering every torrent that changed.
    /// Preferred over calling a blocking `status()` per torrent.
    void requestStatusUpdates();
    /// Asks every torrent with unsaved changes to emit `resumeDataSaved`.
    /// Returns how many alerts to expect.
    std::int32_t requestResumeData();

    /// The port the session actually bound to. Useful when the configuration
    /// asked for an ephemeral port.
    std::int32_t listenPort() const;

    /// Manually introduces a peer, bypassing trackers and DHT. Lets two local
    /// sessions find each other without any external infrastructure.
    Result addPeer(const std::string &infoHash, const std::string &host,
                   std::int32_t port);

    /// Applies settings that can change while the session runs. Listen
    /// interfaces and the disk-IO backend are fixed at startup and ignored here.
    Result applySettings(const SessionConfig &config);

    /// Blocks connections from addresses in the given CIDR ranges.
    Result setBlockedRanges(const StringList &cidrRanges);

    /// Stops the session. libtorrent's shutdown is asynchronous, so this blocks
    /// until it settles. Safe to call more than once.
    void shutdown();

private:
    explicit Session(const SessionConfig &config);
    // The annotation has to repeat here: Swift reads the friend declaration.
    friend Session *sessionCreate(const SessionConfig &config) SWIFT_RETURNS_RETAINED;
    friend void ::torrentBridgeSessionRetain(Session *session);
    friend void ::torrentBridgeSessionRelease(Session *session);

    struct Impl;
    Impl *m_impl;
};

/// Starts a session, or returns null if libtorrent threw during startup.
/// The returned object already carries a reference, so Swift must not retain
/// it again — hence SWIFT_RETURNS_RETAINED.
Session *sessionCreate(const SessionConfig &config) SWIFT_RETURNS_RETAINED;

/// Builds a .torrent file describing `contentPath`, writing it to
/// `outputPath`. Trackerless by design: the tests introduce peers directly.
Result createTorrentFile(const std::string &contentPath, const std::string &outputPath,
                         std::int32_t pieceLength);

/// libtorrent's version, e.g. "2.0.14". Proves the whole stack —
/// Swift -> facade -> libtorrent -> Boost/OpenSSL — is wired up.
std::string libtorrentVersion();

/// OpenSSL's version, read by *calling into libcrypto* rather than from a
/// header macro, so a passing test proves the library is actually linked and
/// not merely that its headers were on the include path.
std::string opensslVersion();

/// Whether libtorrent was compiled with OpenSSL support. False means no HTTPS
/// trackers and no SSL torrents, regardless of OpenSSL being linked.
bool libtorrentHasSSL();

/// Parses a .torrent file and returns its name. Also exercises the error path:
/// libtorrent throws on malformed input, and this must surface that as a failed
/// Result rather than letting it reach Swift.
Result torrentNameFromFile(const std::string &path, std::string &outName);

} // namespace torrentbridge
