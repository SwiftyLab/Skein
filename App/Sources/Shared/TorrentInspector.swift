import SwiftUI
import TorrentKit

/// Detail panel for the current selection.
///
/// Shared between the Mac inspector and the iOS detail screen, so the two never
/// drift apart on what a torrent's details are.
struct TorrentInspector: View {
    let torrents: [TorrentStatus]

    var body: some View {
        Group {
            switch torrents.count {
            case 0:
                ContentUnavailableView(
                    "No Selection", systemImage: "square.dashed",
                    description: Text("Select a torrent to see its details."))
            case 1:
                SingleTorrentDetail(torrent: torrents[0])
            default:
                MultipleSelectionSummary(torrents: torrents)
            }
        }
    }
}

private struct SingleTorrentDetail: View {
    let torrent: TorrentStatus

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(torrent.name).font(.headline).lineLimit(3)
                    } icon: {
                        Image(systemName: torrent.symbolName)
                            .foregroundStyle(torrent.tint)
                    }
                    ProgressView(value: torrent.progress)
                    HStack {
                        Text(torrent.statusText)
                        Spacer()
                        Text(Format.percent(torrent.progress)).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let errorMessage = torrent.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            Section("Transfer") {
                row("Downloaded", Format.bytes(torrent.totalWantedDone))
                row("Total size", Format.bytes(torrent.totalWanted))
                row("Download rate", Format.rate(torrent.downloadRate))
                row("Upload rate", Format.rate(torrent.uploadRate))
                row("Uploaded", Format.bytes(torrent.totalUploaded))
                row("Ratio", ratioText)
                row("Time remaining", Format.duration(torrent.estimatedTimeRemaining))
            }

            Section("Peers") {
                row("Connected", "\(torrent.peerCount)")
                row("Seeds", "\(torrent.seedCount)")
            }

            Section {
                NavigationLink {
                    FilesView(torrent: torrent)
                } label: {
                    Label("Files", systemImage: "doc.on.doc")
                }
                NavigationLink {
                    PeersView(torrent: torrent)
                } label: {
                    Label("Peers", systemImage: "person.2")
                        .badge(torrent.peerCount)
                }
                NavigationLink {
                    TrackersView(torrent: torrent)
                } label: {
                    Label("Trackers", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink {
                    PiecesView(torrent: torrent)
                } label: {
                    Label("Pieces", systemImage: "square.grid.3x3")
                }
                NavigationLink {
                    TorrentOptionsView(torrent: torrent)
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
            }

            Section("Details") {
                row("Save path", torrent.savePath, selectable: true)
                row("Info hash", torrent.infoHash.value, selectable: true, monospaced: true)
                row("Metadata", torrent.hasMetadata ? "Available" : "Fetching…")
            }
        }
        .formStyle(.grouped)
    }

    /// Uploaded over downloaded. Uses total downloaded rather than the selected
    /// size, so it matches what other clients report.
    private var ratioText: String {
        guard torrent.totalDownloaded > 0 else { return "—" }
        let ratio = Double(torrent.totalUploaded) / Double(torrent.totalDownloaded)
        return String(format: "%.2f", ratio)
    }

    @ViewBuilder
    private func row(
        _ label: String, _ value: String,
        selectable: Bool = false, monospaced: Bool = false
    ) -> some View {
        LabeledContent(label) {
            let text = Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .foregroundStyle(.secondary)
            // `.enabled` and `.disabled` are different types, so they cannot be
            // chosen with a ternary.
            Group {
                if selectable {
                    text.textSelection(.enabled)
                } else {
                    text.textSelection(.disabled)
                }
            }
            .lineLimit(monospaced ? 2 : 1)
            .truncationMode(.middle)
            .multilineTextAlignment(.trailing)
        }
    }
}

private struct MultipleSelectionSummary: View {
    let torrents: [TorrentStatus]

    var body: some View {
        Form {
            Section("\(torrents.count) Torrents Selected") {
                LabeledContent("Total size", value: Format.bytes(
                    torrents.reduce(0) { $0 + $1.totalWanted }))
                LabeledContent("Downloaded", value: Format.bytes(
                    torrents.reduce(0) { $0 + $1.totalWantedDone }))
                LabeledContent("Download rate", value: Format.rate(
                    torrents.reduce(0) { $0 + $1.downloadRate }))
                LabeledContent("Upload rate", value: Format.rate(
                    torrents.reduce(0) { $0 + $1.uploadRate }))
            }
        }
        .formStyle(.grouped)
    }
}
