import SwiftUI
import TorrentKit

/// Menu bar commands. Mac users expect these to exist even when the toolbar
/// offers the same actions.
struct TorrentCommands: Commands {
    @FocusedValue(\.torrentManager) private var manager

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Torrent…") {
                NotificationCenter.default.post(name: .showAddTorrent, object: nil)
            }
            .keyboardShortcut("n")

            Button("Add Magnet from Clipboard") {
                guard let text = NSPasteboard.general.string(forType: .string),
                      text.hasPrefix("magnet:") else { return }
                Task { await manager?.addMagnet(text) }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(manager == nil)
        }

        CommandMenu("Transfers") {
            Button("Pause All") {
                Task {
                    guard let manager else { return }
                    for torrent in manager.torrents where !torrent.isPaused {
                        await manager.pause(torrent.infoHash)
                    }
                }
            }
            Button("Resume All") {
                Task {
                    guard let manager else { return }
                    for torrent in manager.torrents where torrent.isPaused {
                        await manager.resume(torrent.infoHash)
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    /// Derived from the bundle identifier so it stays unique if that changes.
    static let showAddTorrent = Notification.Name(
        "\(Bundle.main.bundleIdentifier ?? "dev.soumyamahunt.skein").showAdd")
}

/// Lets menu commands reach the manager owned by the focused window.
struct TorrentManagerFocusKey: FocusedValueKey {
    typealias Value = TorrentManager
}

extension FocusedValues {
    var torrentManager: TorrentManager? {
        get { self[TorrentManagerFocusKey.self] }
        set { self[TorrentManagerFocusKey.self] = newValue }
    }
}
