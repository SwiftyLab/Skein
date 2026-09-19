import SwiftUI
import TorrentKit

/// The iOS shell: a list that pushes to detail.
///
/// Structured differently from the Mac window on purpose — a multi-column table
/// with an inspector does not fit a phone, so this is a list with swipe actions
/// and a pushed detail screen.
struct PhoneContentView: View {
    @Environment(TorrentManager.self) private var manager

    @State private var filter: TorrentFilter = .all
    @State private var isShowingAddSheet = false
    @State private var pendingRemoval: TorrentStatus?
    @State private var isShowingSettings = false
    @State private var isShowingFeeds = false
    @State private var backgroundRequest: BackgroundRequestState = .idle

    /// `BGContinuedProcessingTask` can only be submitted from the foreground in
    /// response to a deliberate action, so this is a button rather than
    /// something the app arranges on its own.
    private enum BackgroundRequestState {
        case idle, running, failed(String)
    }

    private var hasActiveTransfers: Bool {
        manager.torrents.contains { !$0.isFinished && !$0.isPaused }
    }

    private var visibleTorrents: [TorrentStatus] {
        manager.torrents.filter { $0.matches(filter) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleTorrents) { torrent in
                    NavigationLink {
                        TorrentInspector(torrents: [torrent])
                            .navigationTitle(torrent.name)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        TorrentRow(torrent: torrent)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16,
                                              bottom: 12, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .padding(.horizontal, 12)
                    )
                    // Pause on one side, delete on the other, so the
                    // destructive action is never adjacent to the routine one.
                    // Full swipe is allowed for pause because it is reversible,
                    // and withheld for delete because it is not.
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await manager.toggle(torrent) }
                        } label: {
                            Label(torrent.isPaused ? "Resume" : "Pause",
                                  systemImage: torrent.isPaused ? "play.fill" : "pause.fill")
                        }
                        .tint(torrent.isPaused ? .green : .orange)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingRemoval = torrent
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            // Cards rather than flat rows, the way Settings groups its
            // content: each torrent is its own surface, which suits a row that
            // is several lines of mixed information rather than one label.
            //
            // The card is drawn as a row background rather than a container
            // inside the row, so swipe actions still sweep the whole row and
            // the corners stay clipped as it moves.
            .listStyle(.plain)
            .listRowSpacing(10)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Skein")
            .overlay { if manager.torrents.isEmpty { emptyState } }
            .overlay(alignment: .bottom) {
                if case .failed(let message) = backgroundRequest {
                    Label("Could not keep running in the background: \(message)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            requestBackgroundTransfers()
                        } label: {
                            Label(backgroundLabel, systemImage: "moon.zzz")
                        }
                        .disabled(!hasActiveTransfers || isBackgroundRunning)

                        Divider()

                        Button { isShowingFeeds = true } label: {
                            Label("Feeds", systemImage: "dot.radiowaves.up.forward")
                        }
                        Button { isShowingSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isShowingAddSheet = true } label: {
                        Label("Add Torrent", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .status) { rates }
            }
            .sheet(isPresented: $isShowingAddSheet) { AddTorrentSheet() }
            .sheet(isPresented: $isShowingSettings) {
                NavigationStack { SettingsView() }
            }
            .sheet(isPresented: $isShowingFeeds) {
                NavigationStack { FeedsView() }
            }
            .confirmationDialog(
                "Remove Torrent?",
                isPresented: .init(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }),
                presenting: pendingRemoval
            ) { torrent in
                Button("Remove", role: .destructive) {
                    Task { await manager.remove(torrent.infoHash, deleteFiles: false) }
                }
                Button("Remove and Delete Data", role: .destructive) {
                    Task { await manager.remove(torrent.infoHash, deleteFiles: true) }
                }
            } message: { torrent in
                Text(torrent.name)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(TorrentFilter.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbolName).tag(item)
                }
            }
        } label: {
            Label(filter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var isBackgroundRunning: Bool {
        if case .running = backgroundRequest { return true }
        return false
    }

    private var backgroundLabel: String {
        switch backgroundRequest {
        case .idle: return "Keep Downloading in Background"
        case .running: return "Running in Background"
        case .failed: return "Background Request Failed"
        }
    }

    private func requestBackgroundTransfers() {
        do {
            try BackgroundCoordinator.requestContinuedProcessing()
            backgroundRequest = .running
        } catch {
            backgroundRequest = .failed(String(describing: error))
        }
    }

    private var rates: some View {
        HStack(spacing: 12) {
            Label(Format.rate(manager.downloadRate), systemImage: "arrow.down")
            Label(Format.rate(manager.uploadRate), systemImage: "arrow.up")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Torrents", systemImage: "arrow.down.circle")
        } description: {
            Text("Add a magnet link or a .torrent file to get started.")
        } actions: {
            Button("Add Torrent…") { isShowingAddSheet = true }
        }
    }
}

struct TorrentRow: View {
    let torrent: TorrentStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(torrent.name).lineLimit(2).font(.body)
            } icon: {
                Image(systemName: torrent.symbolName).foregroundStyle(torrent.tint)
            }

            ProgressView(value: torrent.progress)

            HStack(spacing: 10) {
                Text(torrent.statusText)
                Spacer()
                if torrent.downloadRate > 0 {
                    Label(Format.rate(torrent.downloadRate), systemImage: "arrow.down")
                }
                if torrent.uploadRate > 0 {
                    Label(Format.rate(torrent.uploadRate), systemImage: "arrow.up")
                }
                Text(Format.bytes(torrent.totalWanted))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
