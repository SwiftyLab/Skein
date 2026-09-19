import SwiftUI
import TorrentKit
import UniformTypeIdentifiers

/// Adds a torrent by magnet link or by picking a `.torrent` file.
struct AddTorrentSheet: View {
    @Environment(TorrentManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    @State private var magnetText = ""
    @State private var isShowingFileImporter = false
    @State private var saveDirectory: URL?
    @State private var options = TorrentManager.AddOptions()

    private var trimmedMagnet: String {
        magnetText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        trimmedMagnet.hasPrefix("magnet:") || trimmedMagnet.count == 40
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Magnet link or info hash") {
                    TextField("magnet:?xt=urn:btih:…", text: $magnetText, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }

                if manager.needsDownloadFolderReselection {
                    Section {
                        Label("The folder you chose before is no longer reachable. "
                              + "Pick it again to keep downloading there.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Save to") {
                    HStack {
                        Text(saveDirectory?.lastPathComponent
                            ?? manager.defaultDownloadDirectory.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        #if os(macOS)
                        Button("Choose…") { chooseSaveDirectory() }
                        #endif
                    }
                }

                Section("Download order") {
                    Toggle("Download in order", isOn: $options.isSequential)
                    Toggle("Prioritise first and last pieces",
                           isOn: $options.prioritisesFirstAndLastPieces)
                    Text("Turn both on to watch or listen before the download "
                         + "finishes. Most media files keep their index at the "
                         + "end, so a player needs both ends before it can open "
                         + "anything. Costs some speed, because pieces are no "
                         + "longer fetched rarest-first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("Choose a .torrent file…", systemImage: "doc.badge.plus")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addMagnet() }.disabled(!canAdd)
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [Self.torrentType],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }

    /// `.torrent` has no system-declared UTType, so declare it here.
    static let torrentType = UTType(filenameExtension: "torrent") ?? .data

    private func addMagnet() {
        // A bare info hash is a convenience: wrap it into a magnet URI.
        let uri = trimmedMagnet.hasPrefix("magnet:")
            ? trimmedMagnet
            : "magnet:?xt=urn:btih:\(trimmedMagnet)"
        let destination = saveDirectory
        let chosen = options
        Task {
            await manager.addMagnet(uri, savePath: destination, options: chosen)
            dismiss()
        }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        let destination = saveDirectory
        let chosen = options
        Task {
            for url in urls {
                // Files delivered by the importer are security-scoped; access
                // must be held while libtorrent reads them.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                await manager.addTorrentFile(
                    at: url, savePath: destination, options: chosen)
            }
            dismiss()
        }
    }

    #if os(macOS)
    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveDirectory = url
        // Hand it to the manager so a bookmark is stored and sandbox access is
        // held for the session — libtorrent writes with POSIX calls and cannot
        // acquire the scope itself.
        manager.setDownloadDirectory(url)
    }
    #endif
}
