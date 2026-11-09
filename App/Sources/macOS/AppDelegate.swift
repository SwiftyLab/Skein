import AppKit

/// Holds quitting until the engine has saved resume data and stopped.
///
/// SwiftUI gives no quit hook of its own, and without this nothing was written
/// on the way out, so every relaunch came back with an empty torrent list.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: TorrentManager?
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager, manager.isRunning else { return .terminateNow }
        // A second Quit while the first is saving just waits on the first.
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            await manager.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
