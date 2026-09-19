import SwiftUI
import TorrentKit

/// The Mac window: filter sidebar, torrent table, detail inspector.
///
/// Deliberately a different shape from the iOS shell — a table with sortable
/// columns and an inspector suits a pointer and a large window, where a stack
/// of navigation pushes does not.
struct MacContentView: View {
    @Environment(TorrentManager.self) private var manager

    @State private var filter: TorrentFilter = .all
    @State private var selection: Set<InfoHash> = []
    @State private var sortOrder = [KeyPathComparator(\TorrentStatus.name)]
    @State private var isShowingAddSheet = false
    @State private var isInspectorPresented = true
    @State private var pendingRemoval: RemovalRequest?
    @State private var isShowingSettings = false
    @State private var isShowingFeeds = false

    /// Carries whether the user asked to delete the data too, so the
    /// confirmation can say which it is.
    private struct RemovalRequest: Identifiable {
        let id = UUID()
        let hashes: [InfoHash]
        let deleteFiles: Bool
    }

    private var visibleTorrents: [TorrentStatus] {
        manager.torrents.filter { $0.matches(filter) }.sorted(using: sortOrder)
    }

    private var selectedTorrents: [TorrentStatus] {
        manager.torrents.filter { selection.contains($0.infoHash) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            table
                .inspector(isPresented: $isInspectorPresented) {
                    TorrentInspector(torrents: selectedTorrents)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
                }
        }
        .navigationTitle("Skein")
        .toolbar { toolbarContent }
        .sheet(isPresented: $isShowingAddSheet) { AddTorrentSheet() }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $isShowingFeeds) {
            NavigationStack { FeedsView() }
                .frame(minWidth: 520, minHeight: 440)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddTorrent)) { _ in
            isShowingAddSheet = true
        }
        .alert(item: $pendingRemoval) { request in
            removalAlert(request)
        }
        .onDrop(of: [AddTorrentSheet.torrentType], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section("Torrents") {
                ForEach(TorrentFilter.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbolName)
                        .badge(manager.torrents.filter { $0.matches(item) }.count)
                        .tag(item)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        .safeAreaInset(edge: .bottom) { transferRates }
    }

    private var transferRates: some View {
        HStack(spacing: 14) {
            Label(Format.rate(manager.downloadRate), systemImage: "arrow.down")
                .foregroundStyle(.green)
            Label(Format.rate(manager.uploadRate), systemImage: "arrow.up")
                .foregroundStyle(.blue)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Table

    private var table: some View {
        Table(visibleTorrents, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { torrent in
                Label {
                    Text(torrent.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: torrent.symbolName).foregroundStyle(torrent.tint)
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Progress", value: \.progress) { torrent in
                HStack(spacing: 6) {
                    ProgressView(value: torrent.progress).controlSize(.small)
                    Text(Format.percent(torrent.progress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            .width(min: 120, ideal: 150)

            TableColumn("Size", value: \.totalWanted) { torrent in
                Text(Format.bytes(torrent.totalWanted)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Down", value: \.downloadRate) { torrent in
                Text(Format.rate(torrent.downloadRate)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Up", value: \.uploadRate) { torrent in
                Text(Format.rate(torrent.uploadRate)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Peers", value: \.peerCount) { torrent in
                Text("\(torrent.seedCount)/\(torrent.peerCount)").monospacedDigit()
            }
            .width(min: 55, ideal: 70)

            TableColumn("ETA") { torrent in
                Text(Format.duration(torrent.estimatedTimeRemaining)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("Status", value: \.statusText) { torrent in
                Text(torrent.statusText).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: InfoHash.self) { hashes in
            contextMenu(for: hashes)
        }
        .overlay {
            if manager.torrents.isEmpty { emptyState }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Torrents", systemImage: "arrow.down.circle")
        } description: {
            Text("Add a magnet link, or drop a .torrent file here.")
        } actions: {
            Button("Add Torrent…") { isShowingAddSheet = true }
        }
    }

    @ViewBuilder
    private func contextMenu(for hashes: Set<InfoHash>) -> some View {
        let targets = hashes.isEmpty ? selection : hashes
        let torrents = manager.torrents.filter { targets.contains($0.infoHash) }

        Button(torrents.allSatisfy(\.isPaused) ? "Resume" : "Pause") {
            Task { for torrent in torrents { await manager.toggle(torrent) } }
        }
        Button("Force Recheck") {
            Task { for hash in targets { await manager.recheck(hash) } }
        }
        Divider()
        Button("Show in Finder") { revealInFinder(torrents) }
        Divider()
        Button("Remove", role: .destructive) {
            pendingRemoval = RemovalRequest(hashes: Array(targets), deleteFiles: false)
        }
        Button("Remove and Delete Data", role: .destructive) {
            pendingRemoval = RemovalRequest(hashes: Array(targets), deleteFiles: true)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { isShowingAddSheet = true } label: {
                Label("Add Torrent", systemImage: "plus")
            }
            .keyboardShortcut("n")

            Button {
                Task { for torrent in selectedTorrents { await manager.toggle(torrent) } }
            } label: {
                Label("Pause or Resume", systemImage: "playpause")
            }
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                pendingRemoval = RemovalRequest(hashes: Array(selection), deleteFiles: false)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(selection.isEmpty)

            Spacer()

            Button { isShowingFeeds = true } label: {
                Label("Feeds", systemImage: "dot.radiowaves.up.forward")
            }
            Button { isShowingSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    // MARK: - Actions

    private func removalAlert(_ request: RemovalRequest) -> Alert {
        let count = request.hashes.count
        let subject = count == 1 ? "this torrent" : "\(count) torrents"
        return Alert(
            title: Text(request.deleteFiles ? "Remove and Delete Data?" : "Remove?"),
            message: Text(
                request.deleteFiles
                    ? "The downloaded files for \(subject) will be deleted. This cannot be undone."
                    : "\(subject.capitalized) will be removed. Downloaded files are kept."),
            primaryButton: .destructive(Text("Remove")) {
                Task {
                    for hash in request.hashes {
                        await manager.remove(hash, deleteFiles: request.deleteFiles)
                    }
                    selection.removeAll()
                }
            },
            secondaryButton: .cancel()
        )
    }

    private func revealInFinder(_ torrents: [TorrentStatus]) {
        let urls = torrents.map {
            URL(fileURLWithPath: $0.savePath).appendingPathComponent($0.name)
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadTransferable(type: URL.self) { result in
                guard case .success(let url) = result else { return }
                Task { await manager.addTorrentFile(at: url) }
            }
        }
        return !providers.isEmpty
    }
}
