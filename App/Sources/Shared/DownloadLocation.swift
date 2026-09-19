import Foundation

/// Remembers the download directory across launches, holding sandbox access open
/// for as long as the engine is running.
///
/// This exists because libtorrent writes files with plain POSIX calls and knows
/// nothing about the App Sandbox. A directory the user picked outside the app
/// container is only writable while a security-scoped resource is *actively*
/// held — and access granted by a picker does not survive relaunch, so a
/// bookmark has to be stored and re-resolved.
///
/// Getting this wrong does not look like a permissions error. libtorrent fails
/// the write deep inside its disk thread and surfaces something that reads like
/// a corrupt torrent, so the failure is worth preventing rather than debugging.
@MainActor
final class DownloadLocation {
    private static let bookmarkKey = "dev.soumyamahunt.skein.downloadDirectoryBookmark"

    private let defaults: UserDefaults
    private var accessedURL: URL?

    /// The directory downloads are written to, or nil if none has been chosen
    /// and the default is in use.
    private(set) var directory: URL?

    /// True when the stored bookmark could not be resolved — the folder was
    /// moved, renamed or deleted — and the caller should ask again.
    private(set) var needsReselection = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Records a directory the user picked and begins holding access to it.
    func adopt(_ url: URL) throws {
        stopAccessing()

        #if os(macOS)
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        #else
        // iOS has no `.withSecurityScope` when creating; scope is implied for
        // URLs that came from a document picker.
        let data = try url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif

        defaults.set(data, forKey: Self.bookmarkKey)
        beginAccessing(url)
        needsReselection = false
    }

    /// Re-resolves the stored bookmark and starts holding access again.
    /// Returns the directory, or nil when there is nothing stored or it is stale.
    @discardableResult
    func restore() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }

        var isStale = false
        let url: URL?
        do {
            #if os(macOS)
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            #else
            url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            #endif
        } catch {
            needsReselection = true
            defaults.removeObject(forKey: Self.bookmarkKey)
            return nil
        }

        guard let resolved = url else {
            needsReselection = true
            return nil
        }

        beginAccessing(resolved)

        // A stale bookmark still resolves, but will not keep working. Refresh it
        // now rather than losing the location at some later launch.
        if isStale {
            try? adopt(resolved)
        }
        return resolved
    }

    /// Releases the sandbox resource. Must be called before the process exits;
    /// leaking these exhausts a per-process limit.
    func stopAccessing() {
        if let accessedURL {
            accessedURL.stopAccessingSecurityScopedResource()
            self.accessedURL = nil
        }
        directory = nil
    }

    func forget() {
        stopAccessing()
        defaults.removeObject(forKey: Self.bookmarkKey)
        needsReselection = false
    }

    private func beginAccessing(_ url: URL) {
        // A container-relative URL needs no scope, and asking for one returns
        // false, so a false result is only meaningful outside the container.
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
        directory = url
    }
}
