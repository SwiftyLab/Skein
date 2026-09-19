import Foundation
import UserNotifications

#if os(macOS)
import AppKit
#endif

/// Tells the user when a download finishes, and shows overall progress on the
/// Dock icon.
///
/// Both are things a transfer app is expected to do, because the whole point is
/// that you stop watching it.
@MainActor
final class CompletionNotifier {
    private var hasRequestedAuthorization = false
    /// Torrents already announced, so a torrent that finishes and then gets
    /// rechecked does not notify twice.
    private var announced: Set<InfoHashKey> = []

    /// The info hash as a plain string; avoids importing TorrentKit types into
    /// a set purely for identity.
    private struct InfoHashKey: Hashable { let value: String }

    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    func torrentFinished(name: String, infoHash: String) async {
        let key = InfoHashKey(value: infoHash)
        guard !announced.contains(key) else { return }
        announced.insert(key)

        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = name
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "finished-\(infoHash)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func forget(_ infoHash: String) {
        announced.remove(InfoHashKey(value: infoHash))
    }

    /// Shows aggregate progress on the Dock icon, or clears it when nothing is
    /// active. macOS only; iOS has no equivalent.
    func updateDockProgress(fraction: Double?, activeCount: Int) {
        #if os(macOS)
        let tile = NSApplication.shared.dockTile
        if let fraction, activeCount > 0 {
            tile.badgeLabel = "\(Int((fraction * 100).rounded()))%"
        } else {
            tile.badgeLabel = nil
        }
        tile.display()
        #endif
    }
}
