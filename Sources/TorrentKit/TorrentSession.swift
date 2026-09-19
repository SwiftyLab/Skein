import Foundation
import Synchronization
import TorrentBridge

/// A one-way flag shared between the actor and the pump thread.
///
/// `Atomic` is non-copyable, so it cannot be captured directly by the pump
/// thread's closure; holding it in a final class gives something shareable.
private final class StopFlag: Sendable {
    private let value = Atomic<Bool>(false)

    var isSet: Bool { value.load(ordering: .acquiring) }

    /// Sets the flag, returning whether it was already set.
    func set() -> Bool { value.exchange(true, ordering: .acquiringAndReleasing) }
}

/// Holds the C++ session across threads.
///
/// `torrentbridge.Session` is an imported C++ type and so not `Sendable`. It is
/// safe to share because libtorrent's session is internally synchronised: the
/// pump thread only ever blocks in `waitAndDrainAlerts`, while the actor calls
/// the mutating operations.
private final class SessionBox: @unchecked Sendable {
    let session: torrentbridge.Session

    init(_ session: torrentbridge.Session) {
        self.session = session
    }
}

/// A running libtorrent session.
///
/// Events arrive on ``events`` rather than through callbacks, because C++ can't
/// call back into Swift under interop. A dedicated thread blocks on libtorrent's
/// alert queue and feeds the stream.
public actor TorrentSession {
    /// How long the pump blocks waiting for alerts before looping. Short enough
    /// that shutdown is responsive, long enough not to spin.
    private static let alertWaitMilliseconds: Int32 = 250

    private let box: SessionBox
    private let stopFlag = StopFlag()
    private let continuation: AsyncStream<SessionEvent>.Continuation

    /// Every event from the session. Bounded, so a slow consumer costs the
    /// newest events rather than unbounded memory.
    public nonisolated let events: AsyncStream<SessionEvent>

    private var pollingTask: Task<Void, Never>?

    public init(configuration: SessionConfiguration = SessionConfiguration()) throws {
        guard let session = torrentbridge.sessionCreate(configuration.makeBridgeConfig()) else {
            throw TorrentError.sessionStartFailed
        }
        let box = SessionBox(session)
        self.box = box

        var capturedContinuation: AsyncStream<SessionEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(4096)) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation

        startPump()
    }

    deinit {
        _ = stopFlag.set()
        continuation.finish()
        pollingTask?.cancel()
    }

    /// Runs the blocking drain on a thread of its own.
    ///
    /// Deliberately a `Thread` and not a `Task`: blocking a cooperative-pool
    /// thread can starve unrelated work, and this call blocks by design.
    private nonisolated func startPump() {
        let box = self.box
        let stopFlag = self.stopFlag
        let continuation = self.continuation

        let thread = Thread {
            while !stopFlag.isSet {
                let alerts = box.session.waitAndDrainAlerts(Self.alertWaitMilliseconds)
                for alert in alerts {
                    guard let event = SessionEvent(alert) else { continue }
                    continuation.yield(event)
                }
            }
            continuation.finish()
        }
        thread.name = "dev.soumyamahunt.skein.alert-pump"
        // libtorrent hands over sizeable alert batches; the default 512 KB is
        // tight for the conversion work done per batch.
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Starts asking libtorrent for status updates on a timer. Each tick yields
    /// a `statusUpdated` event per torrent that changed.
    public func startPollingStatus(every interval: Duration = .seconds(1)) {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.requestStatusUpdates()
            }
        }
    }

    public func stopPollingStatus() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Adding torrents

    @discardableResult
    public func addMagnet(_ uri: String, savePath: URL) throws -> InfoHash {
        try checkRunning()
        let result = box.session.addMagnet(std.string(uri), std.string(savePath.path))
        guard result.ok else { throw TorrentError.engine(String(result.message)) }
        return InfoHash(String(result.infoHash))
    }

    @discardableResult
    public func addTorrentFile(
        at url: URL,
        savePath: URL,
        resumeData: Data? = nil
    ) throws -> InfoHash {
        try checkRunning()
        let result: torrentbridge.AddResult
        if let resumeData, !resumeData.isEmpty {
            var buffer = torrentbridge.ByteBuffer()
            buffer.reserve(resumeData.count)
            for byte in resumeData { buffer.push_back(byte) }
            result = box.session.addTorrentFileWithResume(
                std.string(url.path), std.string(savePath.path), buffer)
        } else {
            result = box.session.addTorrentFile(
                std.string(url.path), std.string(savePath.path))
        }
        guard result.ok else { throw TorrentError.engine(String(result.message)) }
        return InfoHash(String(result.infoHash))
    }

    /// Re-adds a torrent from previously saved resume data.
    ///
    /// Pass `nil` for `savePath` to use the path recorded in the resume data.
    @discardableResult
    public func addFromResumeData(_ resumeData: Data, savePath: URL? = nil) throws -> InfoHash {
        try checkRunning()
        var buffer = torrentbridge.ByteBuffer()
        buffer.reserve(resumeData.count)
        for byte in resumeData { buffer.push_back(byte) }
        let result = box.session.addFromResumeData(buffer, std.string(savePath?.path ?? ""))
        guard result.ok else { throw TorrentError.engine(String(result.message)) }
        return InfoHash(String(result.infoHash))
    }

    /// Restores everything in `store`, returning the torrents that came back.
    ///
    /// Entries that fail to restore are dropped from the store rather than
    /// retried forever, and reported in the returned `failures`.
    @discardableResult
    public func restore(
        from store: TorrentStore
    ) async -> (restored: [InfoHash], failures: [(InfoHash, any Error)]) {
        var restored: [InfoHash] = []
        var failures: [(InfoHash, any Error)] = []
        for entry in await store.loadAll() {
            do {
                restored.append(try addFromResumeData(entry.data))
            } catch {
                failures.append((entry.infoHash, error))
                await store.remove(entry.infoHash)
            }
        }
        return (restored, failures)
    }

    /// Asks every torrent to save resume data and writes each result to `store`.
    ///
    /// Call before shutting down: libtorrent's shutdown is asynchronous, so the
    /// alerts must be collected first or the progress is lost and the next
    /// launch forces a full recheck.
    @discardableResult
    public func persistResumeData(
        to store: TorrentStore,
        timeout: Duration = .seconds(10)
    ) async -> Int {
        let expected = requestResumeData()
        guard expected > 0 else { return 0 }

        var saved = 0
        let deadline = ContinuousClock.now.advanced(by: timeout)
        for await event in events {
            switch event {
            case .resumeDataSaved(let hash, let data):
                try? await store.save(data, for: hash)
                saved += 1
            case .resumeDataFailed:
                // Counts toward the expected total; the torrent simply had
                // nothing worth saving or libtorrent refused.
                saved += 1
            default:
                continue
            }
            if saved >= expected || ContinuousClock.now >= deadline { break }
        }
        return saved
    }

    // MARK: - Torrent operations

    public func remove(_ infoHash: InfoHash, deleteFiles: Bool = false) throws {
        try checkRunning()
        try check(box.session.removeTorrent(std.string(infoHash.value), deleteFiles))
    }

    public func pause(_ infoHash: InfoHash) throws {
        try checkRunning()
        try check(box.session.pauseTorrent(std.string(infoHash.value)))
    }

    public func resume(_ infoHash: InfoHash) throws {
        try checkRunning()
        try check(box.session.resumeTorrent(std.string(infoHash.value)))
    }

    public func recheck(_ infoHash: InfoHash) throws {
        try checkRunning()
        try check(box.session.recheckTorrent(std.string(infoHash.value)))
    }

    // MARK: - Torrent details

    /// The files in a torrent. Empty until a magnet link's metadata arrives.
    public func files(of infoHash: InfoHash) -> [TorrentFile] {
        box.session.listFiles(std.string(infoHash.value)).map(TorrentFile.init)
    }

    public func peers(of infoHash: InfoHash) -> [TorrentPeer] {
        box.session.listPeers(std.string(infoHash.value)).map(TorrentPeer.init)
    }

    public func trackers(of infoHash: InfoHash) -> [TorrentTracker] {
        box.session.listTrackers(std.string(infoHash.value)).map(TorrentTracker.init)
    }

    /// One flag per piece: true where the piece is complete and verified.
    public func pieceAvailability(of infoHash: InfoHash) -> [Bool] {
        box.session.pieceAvailability(std.string(infoHash.value)).map { $0 != 0 }
    }

    // MARK: - Torrent settings

    /// Sets how much a file matters.
    ///
    /// libtorrent applies this on its own thread, so ``files(of:)`` will keep
    /// reporting the old priority for a short while afterwards. Poll rather
    /// than reading back immediately.
    public func setPriority(
        _ priority: FilePriority, forFileAt index: Int, in infoHash: InfoHash
    ) throws {
        try checkRunning()
        try check(box.session.setFilePriority(
            std.string(infoHash.value), Int32(index), priority.bridgeValue))
    }

    /// Rate limits in bytes per second; zero means unlimited.
    public func setLimits(
        for infoHash: InfoHash, download: Int = 0, upload: Int = 0
    ) throws {
        try checkRunning()
        try check(box.session.setTorrentLimits(
            std.string(infoHash.value), Int32(download), Int32(upload)))
    }

    /// Serves pieces in order, which is what makes playback-while-downloading
    /// possible.
    public func setSequentialDownload(_ enabled: Bool, for infoHash: InfoHash) throws {
        try checkRunning()
        try check(box.session.setSequentialDownload(std.string(infoHash.value), enabled))
    }

    /// Raises the priority of the pieces at both ends of every wanted file.
    ///
    /// Pair this with sequential download for playback: sequential alone gets
    /// the head of the file, but most containers keep their index at the end —
    /// MP4's moov atom, AVI's index, Matroska cues — so a player cannot open
    /// the file until the tail arrives too.
    ///
    /// Needs metadata, so it does nothing on a magnet link until peers supply
    /// it. Reapply once ``SessionEvent/metadataReceived(_:)`` arrives.
    public func setFirstLastPiecePriority(
        _ enabled: Bool, for infoHash: InfoHash
    ) throws {
        try checkRunning()
        try check(box.session.setFirstLastPiecePriority(
            std.string(infoHash.value), enabled))
    }

    /// Whether the ends of a torrent's files are already prioritised.
    ///
    /// Inferred from the live piece priorities rather than remembered, so it
    /// survives a relaunch and reports what libtorrent is actually doing.
    public func hasFirstLastPiecePriority(_ infoHash: InfoHash) -> Bool {
        box.session.hasFirstLastPiecePriority(std.string(infoHash.value))
    }

    /// Lower positions run first.
    public func setQueuePosition(_ position: Int, for infoHash: InfoHash) throws {
        try checkRunning()
        try check(box.session.setQueuePosition(std.string(infoHash.value), Int32(position)))
    }

    public func reannounce(_ infoHash: InfoHash) throws {
        try checkRunning()
        try check(box.session.reannounceTorrent(std.string(infoHash.value)))
    }

    /// Moves a torrent's files and updates its save path.
    ///
    /// Asynchronous: success or failure arrives as ``SessionEvent/storageMoved(_:_:)``
    /// or ``SessionEvent/storageMoveFailed(_:_:)``. Any sandbox access to the
    /// destination has to stay open until then, because the copy happens on
    /// libtorrent's disk thread rather than in this call.
    public func moveStorage(of infoHash: InfoHash, to newPath: URL) throws {
        try checkRunning()
        try check(box.session.moveStorage(std.string(infoHash.value), std.string(newPath.path)))
    }

    /// Renames the torrent's content on disk — the containing folder for a
    /// multi-file torrent, the file itself for a single-file one.
    ///
    /// This renames real files. libtorrent offers no way to change the display
    /// name alone, because that name is part of the metadata the info hash is
    /// computed over.
    ///
    /// Outcome arrives as ``SessionEvent/contentRenamed(_:_:)`` or
    /// ``SessionEvent/contentRenameFailed(_:_:)``.
    public func renameContent(of infoHash: InfoHash, to newName: String) throws {
        try checkRunning()
        try check(box.session.renameContent(std.string(infoHash.value), std.string(newName)))
    }

    // MARK: - Streaming

    /// Asks for a piece within `deadline`, raising its priority relative to
    /// other outstanding requests.
    ///
    /// This, not sequential download, is how libtorrent intends playback to
    /// work: sequential mode lets one slow peer holding an early piece stall
    /// everything, while deadlines reorder requests across all peers.
    public func setDeadline(
        _ deadline: Duration, forPiece pieceIndex: Int, in infoHash: InfoHash
    ) throws {
        try checkRunning()
        let milliseconds = Int32(deadline.components.seconds * 1_000
            + deadline.components.attoseconds / 1_000_000_000_000_000)
        try check(box.session.setPieceDeadline(
            std.string(infoHash.value), Int32(pieceIndex), milliseconds))
    }

    /// Drops every deadline, returning to normal rarest-first piece picking.
    public func clearDeadlines(in infoHash: InfoHash) throws {
        try checkRunning()
        try check(box.session.clearPieceDeadlines(std.string(infoHash.value)))
    }

    /// Where a file sits in the torrent's byte stream, so a byte range can be
    /// mapped onto the pieces covering it. Nil until metadata is available.
    public func locateFile(at index: Int, in infoHash: InfoHash) -> FileLocation? {
        let raw = box.session.locateFile(std.string(infoHash.value), Int32(index))
        guard raw.offset >= 0, raw.pieceLength > 0 else { return nil }
        return FileLocation(raw)
    }

    // MARK: - Session settings

    /// Applies settings that can change while running.
    ///
    /// Listen interfaces, the disk-IO backend and peer exchange are fixed when
    /// the session starts and are ignored here — changing those needs a restart.
    public func apply(_ configuration: SessionConfiguration) throws {
        try checkRunning()
        try check(box.session.applySettings(configuration.makeBridgeConfig()))
    }

    /// Blocks peers in the given CIDR ranges, replacing any previous list.
    public func setBlockedRanges(_ cidrRanges: [String]) throws {
        try checkRunning()
        var vector = torrentbridge.StringList()
        for range in cidrRanges { vector.push_back(std.string(range)) }
        try check(box.session.setBlockedRanges(vector))
    }

    /// The port the session actually bound to, useful when the configuration
    /// asked for an ephemeral one.
    public var listenPort: Int {
        Int(box.session.listenPort())
    }

    /// Manually introduces a peer, bypassing trackers and DHT.
    public func addPeer(_ infoHash: InfoHash, host: String, port: Int) throws {
        try checkRunning()
        try check(box.session.addPeer(std.string(infoHash.value), std.string(host), Int32(port)))
    }

    /// Asks libtorrent to post a status update for every changed torrent.
    /// Results arrive as `statusUpdated` events.
    public func requestStatusUpdates() {
        guard !stopFlag.isSet else { return }
        box.session.requestStatusUpdates()
    }

    /// Asks every torrent with metadata to save resume data, returning how many
    /// `resumeDataSaved` events to expect.
    @discardableResult
    public func requestResumeData() -> Int {
        guard !stopFlag.isSet else { return 0 }
        return Int(box.session.requestResumeData())
    }

    /// Stops the session and ends ``events``. Idempotent.
    ///
    /// libtorrent's shutdown is asynchronous and this blocks until it settles,
    /// so callers that care about resume data should await
    /// ``requestResumeData()`` and collect the events first.
    public func shutdown() {
        guard !stopFlag.set() else { return }
        stopPollingStatus()
        box.session.shutdown()
        continuation.finish()
    }

    // MARK: - Helpers

    private func checkRunning() throws {
        if stopFlag.isSet { throw TorrentError.sessionStopped }
    }

    private func check(_ result: torrentbridge.Result) throws {
        guard result.ok else { throw TorrentError.engine(String(result.message)) }
    }
}
