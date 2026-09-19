import SwiftUI
import TorrentKit

/// The files inside a torrent: per-file priorities, and a play action for media
/// that can be streamed while it downloads.
struct FilesView: View {
    let torrent: TorrentStatus
    @Environment(TorrentManager.self) private var manager

    @State private var files: [TorrentFile] = []
    @State private var streamURL: StreamTarget?

    private struct StreamTarget: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
    }

    var body: some View {
        List {
            if files.isEmpty {
                ContentUnavailableView(
                    "No File List", systemImage: "doc",
                    description: Text(torrent.hasMetadata
                        ? "This torrent has no files."
                        : "Waiting for metadata from peers."))
            }
            ForEach(files) { file in
                FileRow(file: file) { priority in
                    Task {
                        await manager.setPriority(priority, forFileAt: file.index,
                                                  in: torrent.infoHash)
                        await reload()
                    }
                } onPlay: {
                    Task { await play(file) }
                }
            }
        }
        .navigationTitle("Files")
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $streamURL) { target in
            PlayerView(url: target.url, title: target.name)
        }
    }

    private func reload() async {
        files = await manager.files(of: torrent.infoHash)
    }

    private func play(_ file: TorrentFile) async {
        guard let url = await manager.streamURL(forFileAt: file.index,
                                                in: torrent.infoHash,
                                                name: file.name) else { return }
        streamURL = StreamTarget(url: url, name: file.name)
    }
}

private struct FileRow: View {
    let file: TorrentFile
    let onPriorityChange: (FilePriority) -> Void
    let onPlay: () -> Void

    /// Extensions worth offering a play button for. Anything else would just
    /// open a player that fails.
    private var isPlayable: Bool {
        ["mp4", "m4v", "mkv", "avi", "mov", "webm", "mp3", "flac", "m4a"]
            .contains((file.name as NSString).pathExtension.lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(file.name).lineLimit(2).font(.callout)
                Spacer()
                if isPlayable {
                    Button(action: onPlay) {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Stream while downloading")
                }
            }

            if file.priority != .skip {
                ProgressView(value: file.progress)
            }

            HStack {
                Picker("Priority", selection: Binding(
                    get: { file.priority },
                    set: { onPriorityChange($0) }
                )) {
                    ForEach(FilePriority.allCases) { priority in
                        Text(priority.label).tag(priority)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                Spacer()
                Text("\(Format.bytes(file.downloaded)) / \(Format.bytes(file.size))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
