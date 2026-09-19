import SwiftUI
import TorrentKit

/// The peers currently connected for a torrent.
struct PeersView: View {
    let torrent: TorrentStatus
    @Environment(TorrentManager.self) private var manager

    @State private var peers: [TorrentPeer] = []

    var body: some View {
        List {
            if peers.isEmpty {
                ContentUnavailableView(
                    "No Peers", systemImage: "person.2.slash",
                    description: Text("Nobody is connected right now."))
            }
            ForEach(peers) { peer in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(peer.address).font(.callout.monospaced()).lineLimit(1)
                        if peer.isEncrypted {
                            Image(systemName: "lock.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("Connection is encrypted")
                        }
                        Spacer()
                        if peer.isSeed {
                            Text("Seed").font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.green.opacity(0.2), in: Capsule())
                        }
                    }
                    HStack(spacing: 12) {
                        Text(peer.client.isEmpty ? "Unknown client" : peer.client)
                            .lineLimit(1)
                        Spacer()
                        Label(Format.rate(peer.downloadRate), systemImage: "arrow.down")
                        Label(Format.rate(peer.uploadRate), systemImage: "arrow.up")
                        Text(Format.percent(peer.progress))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Peers")
        .task { await poll() }
        .refreshable { peers = await manager.peers(of: torrent.infoHash) }
    }

    /// Peers churn constantly, so this refreshes on a timer rather than once.
    private func poll() async {
        while !Task.isCancelled {
            peers = await manager.peers(of: torrent.infoHash)
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// The trackers a torrent announces to, and whether they are working.
struct TrackersView: View {
    let torrent: TorrentStatus
    @Environment(TorrentManager.self) private var manager

    @State private var trackers: [TorrentTracker] = []

    private func trackerSymbol(_ tracker: TorrentTracker) -> String {
        if tracker.isWorking { return "checkmark.circle.fill" }
        if tracker.lastError != nil { return "exclamationmark.triangle.fill" }
        return "clock"
    }

    private func trackerTint(_ tracker: TorrentTracker) -> Color {
        if tracker.isWorking { return .green }
        if tracker.lastError != nil { return .orange }
        return .secondary
    }

    private func trackerState(_ tracker: TorrentTracker) -> String {
        if tracker.isWorking { return "Working" }
        if tracker.lastError != nil { return "Failing" }
        return "Not yet contacted"
    }

    var body: some View {
        List {
            if trackers.isEmpty {
                ContentUnavailableView(
                    "No Trackers", systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text(
                        "This torrent is trackerless and relies on DHT and peer exchange."))
            }
            ForEach(trackers) { tracker in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        // A symbol rather than a coloured dot: state carried by
                        // colour alone is invisible to anyone who cannot
                        // distinguish the hues.
                        Image(systemName: trackerSymbol(tracker))
                            .foregroundStyle(trackerTint(tracker))
                            .font(.caption)
                            .accessibilityLabel(trackerState(tracker))
                        Text(tracker.url)
                            .font(.callout.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                    }
                    HStack(spacing: 12) {
                        Text("Tier \(tracker.tier)")
                        if tracker.peerCount > 0 { Text("\(tracker.peerCount) peers") }
                        Spacer()
                    }
                    .font(.caption).foregroundStyle(.secondary)

                    if let error = tracker.lastError {
                        Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Trackers")
        .task { trackers = await manager.trackers(of: torrent.infoHash) }
        .refreshable { trackers = await manager.trackers(of: torrent.infoHash) }
        .toolbar {
            Button {
                Task {
                    await manager.reannounce(torrent.infoHash)
                    trackers = await manager.trackers(of: torrent.infoHash)
                }
            } label: {
                Label("Reannounce", systemImage: "arrow.clockwise")
            }
        }
    }
}

/// A map of which pieces have been downloaded and verified.
struct PiecesView: View {
    let torrent: TorrentStatus
    @Environment(TorrentManager.self) private var manager

    @State private var pieces: [Bool] = []

    private var completed: Int { pieces.filter { $0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pieces.isEmpty {
                ContentUnavailableView(
                    "No Piece Map", systemImage: "square.grid.3x3",
                    description: Text("Waiting for metadata."))
            } else {
                Text("\(completed) of \(pieces.count) pieces verified")
                    .font(.callout).foregroundStyle(.secondary)
                PieceMap(pieces: pieces)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Pieces")
        .task { await poll() }
    }

    private func poll() async {
        while !Task.isCancelled {
            pieces = await manager.pieceAvailability(of: torrent.infoHash)
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// Draws the piece map as a grid.
///
/// Uses Canvas rather than a stack of shapes: a large torrent has tens of
/// thousands of pieces, and that many views would crawl.
private struct PieceMap: View {
    let pieces: [Bool]

    var body: some View {
        Canvas { context, size in
            guard !pieces.isEmpty else { return }
            let columns = max(1, Int((size.width / 6).rounded(.down)))
            let rows = Int((Double(pieces.count) / Double(columns)).rounded(.up))
            let cell = min(size.width / Double(columns),
                           max(2, size.height / Double(max(1, rows))))
            let gap = cell > 4 ? 1.0 : 0.0

            for (index, have) in pieces.enumerated() {
                let column = index % columns
                let row = index / columns
                let rect = CGRect(
                    x: Double(column) * cell, y: Double(row) * cell,
                    width: cell - gap, height: cell - gap)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: gap > 0 ? 1 : 0),
                    with: .color(have ? .accentColor : .secondary.opacity(0.22)))
            }
        }
    }
}
