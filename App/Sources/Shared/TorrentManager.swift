import Foundation
import Observation
import TorrentKit

/// The app's view of the engine.
///
/// Owns the session, keeps the canonical torrent list, and drains
/// ``TorrentSession/events`` into observable state for SwiftUI. Everything here
/// is main-actor isolated, so views read it without any further synchronisation.
@MainActor
@Observable
public final class TorrentManager {
    public private(set) var torrents: [TorrentStatus] = []
    public private(set) var isRunning = false
    public private(set) var startupError: String?
    /// Most recent engine errors, newest first, for the UI to surface.
    public private(set) var recentErrors: [EngineError] = []

    public struct EngineError: Identifiable, Sendable {
        public let id = UUID()
        public let infoHash: InfoHash?
        public let message: String
        public let date: Date
    }

    private var session: TorrentSession?
    private var store: TorrentStore?
    private var eventTask: Task<Void, Never>?
    private var streamingServer: StreamingServer?
    private let downloadLocation = DownloadLocation()
    private let notifier = CompletionNotifier()
    /// Options chosen when a torrent was added that could not be applied yet.
    ///
    /// A magnet link has no metadata at add time, so piece priorities cannot be
    /// set until peers supply it. Without deferring, the option silently does
    /// nothing — which is the failure mode people report as "streaming does not
    /// work on magnets".
    private var pendingOptions: [InfoHash: AddOptions] = [:]
    /// Destinations whose sandbox access is held while libtorrent copies into
    /// them, released when the move reports back.
    private var moveDestinations: [InfoHash: URL] = [:]
    private var byInfoHash: [InfoHash: Int] = [:]

    public var downloadRate: Int { torrents.reduce(0) { $0 + $1.downloadRate } }
    public var uploadRate: Int { torrents.reduce(0) { $0 + $1.uploadRate } }

    public init() {}

    /// The directory new torrents download into.
    ///
    /// A directory the user chose, whose sandbox access is held open for the
    /// session, otherwise the platform default inside the container.
    public var defaultDownloadDirectory: URL {
        if let chosen = downloadLocation.directory { return chosen }
        #if os(macOS)
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #endif
    }

    /// True when a previously chosen folder can no longer be reached and the
    /// user needs to pick it again.
    public var needsDownloadFolderReselection: Bool {
        downloadLocation.needsReselection
    }

    /// Adopts a directory the user picked, holding sandbox access for the
    /// session and remembering it across launches.
    public func setDownloadDirectory(_ url: URL) {
        do {
            try downloadLocation.adopt(url)
            // Torrent payloads should not be swept into iCloud.
            excludeFromBackup(url)
        } catch {
            record("Could not keep access to \(url.lastPathComponent): \(error)", for: nil)
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    public func start() async {
        guard session == nil else { return }
        do {
            // Re-open sandbox access before the engine starts, so its very
            // first write already has permission.
            downloadLocation.restore()

            let store = try TorrentStore(directory: try TorrentStore.defaultDirectory())
            let session = try TorrentSession()
            self.store = store
            self.session = session

            // Inherits this method's MainActor isolation, so `apply` is
            // already on the right actor and reaching it needs no await.
            // `events` is nonisolated on the session, and the local `session`
            // is used rather than routing back through `self` — the Task holds
            // it until the stream finishes, which shutdown() causes.
            eventTask = Task { [weak self] in
                for await event in session.events {
                    self?.apply(event)
                }
            }

            let outcome = await session.restore(from: store)
            for failure in outcome.failures {
                record(failure.1.localizedDescription, for: failure.0)
            }
            await session.startPollingStatus(every: .seconds(1))
            await notifier.requestAuthorizationIfNeeded()
            isRunning = true
        } catch {
            startupError = error.localizedDescription
        }
    }

    /// Writes resume data for every torrent without stopping the session.
    ///
    /// Used by the iOS background handlers, which must checkpoint progress at
    /// points where the app may be killed without warning.
    public func persistResumeData() async {
        guard let session, let store else { return }
        await session.persistResumeData(to: store)
    }

    /// Saves resume data, then stops the session.
    ///
    /// Must complete before the process exits, or progress is lost and the next
    /// launch forces a full recheck of every torrent.
    public func shutdown() async {
        guard let session else { return }
        if let store {
            await session.persistResumeData(to: store)
        }
        await streamingServer?.stop()
        streamingServer = nil
        for infoHash in moveDestinations.keys { releaseMoveDestination(infoHash) }
        await session.shutdown()
        eventTask?.cancel()
        eventTask = nil
        self.session = nil
        // Released only after the engine has stopped writing; these are a
        // limited per-process resource.
        downloadLocation.stopAccessing()
        isRunning = false
    }

    // MARK: - Commands

    /// Download options chosen at add time.
    public struct AddOptions: Sendable, Equatable {
        /// Fetch pieces in order rather than rarest-first.
        public var isSequential: Bool
        /// Prioritise the pieces at both ends of each file, which a player
        /// needs because most containers keep their index at the end.
        public var prioritisesFirstAndLastPieces: Bool

        public init(isSequential: Bool = false,
                    prioritisesFirstAndLastPieces: Bool = false) {
            self.isSequential = isSequential
            self.prioritisesFirstAndLastPieces = prioritisesFirstAndLastPieces
        }

        public static let none = AddOptions()
        /// What you want in order to watch something before it has finished.
        public static let streaming = AddOptions(
            isSequential: true, prioritisesFirstAndLastPieces: true)

        var isEmpty: Bool { self == .none }
    }

    public func addTorrentFile(
        at url: URL, savePath: URL? = nil, options: AddOptions = .none
    ) async {
        let destination = savePath ?? defaultDownloadDirectory
        guard let session else { return record("the engine is not running", for: nil) }
        do {
            let hash = try await session.addTorrentFile(at: url, savePath: destination)
            await apply(options, to: hash)
        } catch {
            record(String(describing: error), for: nil)
        }
    }

    /// Deletes a file only if it is a copy the system placed in our own
    /// `Documents/Inbox`.
    ///
    /// Checked by path prefix rather than assumed: the same entry point also
    /// receives files opened in place, which live in other apps' containers or
    /// iCloud and must not be touched.
    public func discardIfInboxCopy(_ url: URL) {
        guard url.isFileURL,
              let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask).first
        else { return }

        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
            .standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(inbox + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Picks up `.torrent` files the share extension left in the app group
    /// container, adds them, and clears them out.
    ///
    /// The extension cannot run the engine itself — its memory limit would kill
    /// a libtorrent session mid-transfer — so it copies the file across and
    /// wakes the app, and this is the other half of that handoff.
    public func drainSharedInbox() async {
        #if os(iOS)
        // Filled by Project.swift from one value shared with the extension;
        // empty when app groups are not enabled for this build.
        let group = Bundle.main.object(forInfoDictionaryKey: "SKAppGroup") as? String ?? ""
        guard !group.isEmpty,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group)
        else { return }

        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil)
        else { return }

        for file in files where file.pathExtension.lowercased() == "torrent" {
            await addTorrentFile(at: file)
            // Removed only after handing it over, so a crash mid-add leaves the
            // file to be retried rather than losing it.
            try? FileManager.default.removeItem(at: file)
        }
        #endif
    }

    public func addMagnet(
        _ uri: String, savePath: URL? = nil, options: AddOptions = .none
    ) async {
        let destination = savePath ?? defaultDownloadDirectory
        guard let session else { return record("the engine is not running", for: nil) }
        do {
            let hash = try await session.addMagnet(uri, savePath: destination)
            await apply(options, to: hash)
        } catch {
            record(String(describing: error), for: nil)
        }
    }

    /// Applies what can be applied now and defers the rest until metadata lands.
    ///
    /// Sequential download is a flag and takes effect immediately. Piece
    /// priorities need the file layout, which a magnet link does not have until
    /// peers supply it — without deferring, the option silently does nothing,
    /// which is exactly the "streaming does not work on magnets" complaint.
    private func apply(_ options: AddOptions, to infoHash: InfoHash) async {
        guard !options.isEmpty, let session else { return }

        if options.isSequential {
            try? await session.setSequentialDownload(true, for: infoHash)
        }
        guard options.prioritisesFirstAndLastPieces else { return }

        let hasMetadata = torrents.first { $0.infoHash == infoHash }?.hasMetadata ?? false
        if hasMetadata {
            try? await session.setFirstLastPiecePriority(true, for: infoHash)
        } else {
            pendingOptions[infoHash] = options
        }
    }

    public func pause(_ infoHash: InfoHash) async {
        await perform { try await $0.pause(infoHash) }
    }

    public func resume(_ infoHash: InfoHash) async {
        await perform { try await $0.resume(infoHash) }
    }

    public func recheck(_ infoHash: InfoHash) async {
        await perform { try await $0.recheck(infoHash) }
    }

    public func remove(_ infoHash: InfoHash, deleteFiles: Bool) async {
        await perform { try await $0.remove(infoHash, deleteFiles: deleteFiles) }
        await store?.remove(infoHash)
    }

    /// Flips pause/resume for a torrent.
    public func toggle(_ status: TorrentStatus) async {
        if status.isPaused {
            await resume(status.infoHash)
        } else {
            await pause(status.infoHash)
        }
    }

    private func perform<T>(
        _ body: @Sendable (TorrentSession) async throws -> T
    ) async {
        guard let session else {
            record("the engine is not running", for: nil)
            return
        }
        do {
            _ = try await body(session)
        } catch {
            record(String(describing: error), for: nil)
        }
    }

    private func record(_ message: String, for infoHash: InfoHash?) {
        recentErrors.insert(
            EngineError(infoHash: infoHash, message: message, date: .now), at: 0)
        if recentErrors.count > 20 { recentErrors.removeLast() }
    }

    public func dismissError(_ id: UUID) {
        recentErrors.removeAll { $0.id == id }
    }

    // MARK: - Files and streaming

    public func files(of infoHash: InfoHash) async -> [TorrentFile] {
        guard let session else { return [] }
        return await session.files(of: infoHash)
    }

    public func setPriority(
        _ priority: FilePriority, forFileAt index: Int, in infoHash: InfoHash
    ) async {
        await perform { try await $0.setPriority(priority, forFileAt: index, in: infoHash) }
    }

    /// A localhost URL a player can open, for a file that may still be
    /// downloading. Turns on sequential-ish behaviour by way of piece
    /// deadlines inside the streaming server.
    public func streamURL(
        forFileAt index: Int, in infoHash: InfoHash, name: String
    ) async -> URL? {
        guard let session else { return nil }
        if streamingServer == nil {
            let server = StreamingServer(session: session)
            do {
                try await server.start()
                streamingServer = server
            } catch {
                record("Could not start the streaming server: \(error)", for: infoHash)
                return nil
            }
        }
        guard let server = streamingServer else { return nil }

        // Wait for the listener to bind before handing out a URL.
        for _ in 0..<50 where await server.port == 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await server.url(forFileAt: index, in: infoHash, name: name)
    }

    public func peers(of infoHash: InfoHash) async -> [TorrentPeer] {
        guard let session else { return [] }
        return await session.peers(of: infoHash)
    }

    public func trackers(of infoHash: InfoHash) async -> [TorrentTracker] {
        guard let session else { return [] }
        return await session.trackers(of: infoHash)
    }

    public func pieceAvailability(of infoHash: InfoHash) async -> [Bool] {
        guard let session else { return [] }
        return await session.pieceAvailability(of: infoHash)
    }

    public func reannounce(_ infoHash: InfoHash) async {
        await perform { try await $0.reannounce(infoHash) }
    }

    public func setLimits(for infoHash: InfoHash, download: Int, upload: Int) async {
        await perform { try await $0.setLimits(for: infoHash, download: download, upload: upload) }
    }

    public func setSequentialDownload(_ enabled: Bool, for infoHash: InfoHash) async {
        await perform { try await $0.setSequentialDownload(enabled, for: infoHash) }
    }

    public func setFirstLastPiecePriority(
        _ enabled: Bool, for infoHash: InfoHash
    ) async {
        await perform { try await $0.setFirstLastPiecePriority(enabled, for: infoHash) }
    }

    public func hasFirstLastPiecePriority(_ infoHash: InfoHash) async -> Bool {
        guard let session else { return false }
        return await session.hasFirstLastPiecePriority(infoHash)
    }

    public func setQueuePosition(_ position: Int, for infoHash: InfoHash) async {
        await perform { try await $0.setQueuePosition(position, for: infoHash) }
    }

    /// Moves a torrent's files to a new folder.
    ///
    /// The destination comes from a picker, so it is security-scoped, and the
    /// copy runs on libtorrent's disk thread rather than in this call. Access
    /// is therefore held until the move reports back, and released in the
    /// event handler — not here, where it would be revoked mid-copy.
    ///
    /// Deliberately does *not* change the app-wide default download folder:
    /// moving one torrent should not silently redirect every future one.
    public func moveStorage(of infoHash: InfoHash, to url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        if scoped { moveDestinations[infoHash] = url }
        await perform { try await $0.moveStorage(of: infoHash, to: url) }
    }

    /// Renames a torrent's content on disk.
    ///
    /// Renames real files — the containing folder, or the file itself for a
    /// single-file torrent. libtorrent cannot change a display name on its own,
    /// because the name is part of the metadata the info hash covers.
    public func renameContent(of infoHash: InfoHash, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform { try await $0.renameContent(of: infoHash, to: trimmed) }
    }

    private func releaseMoveDestination(_ infoHash: InfoHash) {
        guard let url = moveDestinations.removeValue(forKey: infoHash) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    /// Applies settings and an address block list, returning a message on
    /// failure so the settings screen can show what went wrong rather than
    /// failing silently.
    public func apply(
        _ configuration: SessionConfiguration, blockedRanges: [String]
    ) async -> String? {
        guard let session else { return "The engine is not running." }
        do {
            try await session.apply(configuration)
            try await session.setBlockedRanges(blockedRanges)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    // MARK: - Event handling

    private func apply(_ event: SessionEvent) {
        switch event {
        case .torrentAdded(let status), .statusUpdated(let status):
            upsert(status)
            updateDockProgress()
        case .torrentRemoved(let hash):
            if let index = byInfoHash[hash] {
                torrents.remove(at: index)
                reindex()
            }
            notifier.forget(hash.value)
            updateDockProgress()
        case .torrentFailed(let hash, let message),
             .trackerFailed(let hash, let message):
            record(message, for: hash)
        case .storageMoved(let hash, _):
            // Safe to drop the sandbox hold only now the copy has finished.
            releaseMoveDestination(hash)
        case .storageMoveFailed(let hash, let message):
            releaseMoveDestination(hash)
            record("Could not move the files: \(message)", for: hash)
        case .contentRenamed:
            // The new name arrives with the next status update.
            break
        case .contentRenameFailed(let hash, let message):
            record("Could not rename: \(message)", for: hash)
        case .resumeDataSaved(let hash, let data):
            Task { [store] in try? await store?.save(data, for: hash) }
        case .sessionStopped:
            isRunning = false
        case .torrentFinished(let hash):
            let name = torrents.first { $0.infoHash == hash }?.name ?? "Torrent"
            Task { await notifier.torrentFinished(name: name, infoHash: hash.value) }
        case .metadataReceived(let hash):
            // The moment a magnet's piece priorities can finally be set.
            if let options = pendingOptions.removeValue(forKey: hash) {
                Task { [session] in
                    try? await session?.setFirstLastPiecePriority(
                        options.prioritisesFirstAndLastPieces, for: hash)
                }
            }
        case .torrentPaused, .torrentResumed, .torrentChecked,
             .resumeDataFailed, .other:
            // Status polling reflects these; nothing extra to do here.
            break
        }
    }

    /// Aggregate progress across everything still running, for the Dock badge.
    private func updateDockProgress() {
        let active = torrents.filter { !$0.isFinished && !$0.isPaused }
        guard !active.isEmpty else {
            notifier.updateDockProgress(fraction: Double?.none, activeCount: 0)
            return
        }
        let fraction = active.reduce(0.0) { $0 + $1.progress } / Double(active.count)
        notifier.updateDockProgress(fraction: fraction, activeCount: active.count)
    }

    private func upsert(_ status: TorrentStatus) {
        if let index = byInfoHash[status.infoHash] {
            torrents[index] = status
        } else {
            torrents.append(status)
            byInfoHash[status.infoHash] = torrents.count - 1
        }
    }

    private func reindex() {
        byInfoHash = Dictionary(
            uniqueKeysWithValues: torrents.enumerated().map { ($1.infoHash, $0) })
    }
}
