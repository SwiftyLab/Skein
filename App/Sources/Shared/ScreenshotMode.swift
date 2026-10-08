#if DEBUG
import Foundation
import TorrentKit

/// Fixed, offline content for App Store Connect screenshots.
///
/// `Scripts/screenshots.sh` launches the app with `-screenshots YES` and
/// optionally `-screenshotScreen add|settings|feeds`. The engine is never
/// started, so nothing touches the network and every run looks the same.
/// Debug builds only: none of this ships.
enum ScreenshotMode {
    static var isActive: Bool { UserDefaults.standard.bool(forKey: "screenshots") }

    /// Which sheet to open over the list, if any.
    static var screen: String? { UserDefaults.standard.string(forKey: "screenshotScreen") }

    private static let gigabyte: Int64 = 1_000_000_000
    private static let megabyte = 1_000_000

    /// Freely licensed works, so the list shows nothing anyone could object to.
    static let torrents: [TorrentStatus] = [
        TorrentStatus(infoHash: InfoHash("08ada5a7a6183aae1e09d831df6748d566095a10"),
                      name: "Sintel (4K)", state: .downloading, progress: 0.62,
                      totalWanted: 4 * gigabyte + 300_000_000, downloadRate: 8_400_000,
                      uploadRate: 610_000, peerCount: 41, seedCount: 128, isSequential: true),
        TorrentStatus(infoHash: InfoHash("dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"),
                      name: "Big Buck Bunny", state: .seeding, progress: 1,
                      totalWanted: 276_000_000, uploadRate: 1_200_000, peerCount: 12,
                      seedCount: 96, totalUploaded: 2 * gigabyte),
        TorrentStatus(infoHash: InfoHash("a88fda5954e89178c372716a6a78b8180ed4dad3"),
                      name: "ubuntu-26.04-desktop-amd64.iso", state: .downloading,
                      progress: 0.27, totalWanted: 6 * gigabyte, downloadRate: 21 * megabyte,
                      uploadRate: 1_900_000, peerCount: 87, seedCount: 2_340),
        TorrentStatus(infoHash: InfoHash("c9e15763f722f23e98a29decdfae341b98d53056"),
                      name: "Cosmos Laundromat", state: .downloading, progress: 0.08,
                      totalWanted: 1 * gigabyte + 700_000_000, downloadRate: 3_100_000,
                      peerCount: 18, seedCount: 44),
        TorrentStatus(infoHash: InfoHash("6a9759bffd5c0af65319979fb7832189f4f3c35d"),
                      name: "Tears of Steel", state: .seeding, progress: 1,
                      totalWanted: 740_000_000, peerCount: 3, seedCount: 61,
                      totalUploaded: 980_000_000, isPaused: true),
    ]
}
#endif
