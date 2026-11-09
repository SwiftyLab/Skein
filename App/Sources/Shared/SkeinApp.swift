import SwiftUI
import TorrentKit

@main
struct SkeinApp: App {
    @State private var manager: TorrentManager
    @State private var feeds: FeedCoordinator?
    @Environment(\.scenePhase) private var scenePhase

    #if os(iOS)
    @State private var background: BackgroundCoordinator
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        let manager = TorrentManager()
        _manager = State(initialValue: manager)
        #if os(iOS)
        // BGTaskScheduler only accepts handlers registered before launch
        // finishes, which `.task` on the first view is too late for.
        let background = BackgroundCoordinator(manager: manager)
        background.registerHandlers()
        _background = State(initialValue: background)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(manager)
                .environment(feeds)
                .task { await startUp() }
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
                .onOpenURL { url in
                    handleIncoming(url)
                }
        }
        #if os(macOS)
        .defaultSize(width: 1_080, height: 680)
        .commands { TorrentCommands() }
        #endif
    }
}

extension SkeinApp {
    private func startUp() async {
        #if os(macOS)
        appDelegate.manager = manager
        #endif
        await manager.start()
        #if os(iOS)
        await manager.drainSharedInbox()
        #endif
        // Feeds depend on a running engine, so they start second.
        if feeds == nil, let coordinator = try? FeedCoordinator(manager: manager) {
            feeds = coordinator
            await coordinator.start()
        }
    }

    /// Accepts both magnet links and .torrent files handed over by the system.
    private func handleIncoming(_ url: URL) {
        // The share extension opens skein://inbox after dropping a file in the
        // shared container.
        if url.scheme == "skein" {
            Task { await manager.drainSharedInbox() }
            return
        }
        if url.scheme == "magnet" {
            Task { await manager.addMagnet(url.absoluteString) }
            return
        }
        guard url.isFileURL, url.pathExtension.lowercased() == "torrent" else { return }
        Task {
            // Files arriving from other apps are security-scoped, and access
            // has to be held while libtorrent reads them — which it does
            // synchronously inside the add.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await manager.addTorrentFile(at: url)
            // Even with LSSupportsOpeningDocumentsInPlace, some senders still
            // copy into Documents/Inbox. Those copies are ours and nothing
            // clears them, so they would accumulate indefinitely.
            manager.discardIfInboxCopy(url)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        #if os(iOS)
        switch phase {
        case .inactive:
            // Opening the app switcher only makes the app inactive, and
            // swiping it away from there may never reach `.background`, so this
            // is the last moment that is sure to come before a force-quit.
            background.beginSuspensionGrace()
        case .background:
            // The point at which it is known whether a catch-up run is worth
            // queueing; the save is repeated in case progress moved since
            // `.inactive`.
            background.beginSuspensionGrace()
            background.scheduleProcessing()
        case .active:
            // Catches anything shared while the app was not running.
            Task { await manager.drainSharedInbox() }
        default:
            break
        }
        #endif
    }
}

/// Picks the platform shell. The two differ enough in structure — table and
/// inspector versus a navigation stack — that sharing one layout would serve
/// neither well.
struct RootView: View {
    @Environment(TorrentManager.self) private var manager

    var body: some View {
        Group {
            #if os(macOS)
            MacContentView()
            #else
            PhoneContentView()
            #endif
        }
        .overlay(alignment: .top) {
            if let error = manager.startupError {
                StartupErrorBanner(message: error)
            }
        }
    }
}

private struct StartupErrorBanner: View {
    let message: String

    var body: some View {
        Label("The engine could not start: \(message)", systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()
    }
}
