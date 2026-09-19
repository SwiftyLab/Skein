import Foundation

/// Persists resume data so torrents survive relaunch.
///
/// Resume data saved with libtorrent's `save_info_dict` flag carries the
/// torrent metadata as well as progress, so one file per torrent is enough to
/// restore it — the original `.torrent` file or magnet URI is not needed.
public actor TorrentStore {
    private let directory: URL
    private let fileManager = FileManager.default

    /// The default location, under Application Support, excluded from backup.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Skein/Resume", isDirectory: true)
    }

    public init(directory: URL) throws {
        self.directory = directory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Torrent data and its bookkeeping have no business in iCloud.
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func fileURL(for infoHash: InfoHash) -> URL {
        directory.appendingPathComponent("\(infoHash.value).resume", isDirectory: false)
    }

    public func save(_ data: Data, for infoHash: InfoHash) throws {
        try data.write(to: fileURL(for: infoHash), options: .atomic)
    }

    public func remove(_ infoHash: InfoHash) {
        try? fileManager.removeItem(at: fileURL(for: infoHash))
    }

    public func loadAll() -> [(infoHash: InfoHash, data: Data)] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".resume") else { return nil }
            let hash = InfoHash(String(name.dropLast(".resume".count)))
            guard let data = try? Data(contentsOf: fileURL(for: hash)), !data.isEmpty else {
                return nil
            }
            return (hash, data)
        }
    }

    /// Number of stored entries. Cheap check for "is there anything to restore".
    public var count: Int {
        (try? fileManager.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".resume") }.count ?? 0
    }
}
