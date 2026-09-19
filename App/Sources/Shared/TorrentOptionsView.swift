import SwiftUI
import TorrentKit

/// Per-torrent controls: rate limits, sequential download, queue position and
/// where the data lives.
struct TorrentOptionsView: View {
    let torrent: TorrentStatus
    @Environment(TorrentManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    @State private var downloadLimit = 0
    @State private var uploadLimit = 0
    @State private var isSequential = false
    @State private var prioritisesEnds = false
    @State private var queuePosition = 0
    @State private var isMovingStorage = false
    @State private var editedName = ""
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        editedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A name has to be a single path component; libtorrent sanitises too, but
    /// refusing up front explains why rather than silently mangling it.
    private var canRename: Bool {
        !trimmedName.isEmpty
            && trimmedName != torrent.name
            && !trimmedName.contains("/")
            && !trimmedName.contains(":")
            && trimmedName != "."
            && trimmedName != ".."
    }

    var body: some View {
        Form {
            nameSection
            speedSection
            orderSection
            queueSection
            locationSection
            maintenanceSection
        }
        .formStyle(.grouped)
        .navigationTitle("Options")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") { apply() }
            }
        }
        .fileImporter(
            isPresented: $isMovingStorage,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result else { return }
            Task { await manager.moveStorage(of: torrent.infoHash, to: url) }
        }
        .task {
            editedName = torrent.name
            isSequential = torrent.isSequential
            // Read back from libtorrent rather than remembered, so the toggle
            // reflects what is actually set.
            prioritisesEnds = await manager.hasFirstLastPiecePriority(torrent.infoHash)
        }
    }

    // Split into computed sections because one Form containing all of them
    // exceeds what the type checker will solve in reasonable time.

    private var nameSection: some View {
        Section {
            TextField("Torrent name", text: $editedName)
                .focused($isNameFocused)
                #if os(iOS)
                .autocorrectionDisabled()
                #endif
                .onSubmit { rename() }
            Button("Rename") { rename() }
                .disabled(!canRename || !torrent.hasMetadata)
        } header: {
            Text("Name")
        } footer: {
            Text(torrent.hasMetadata
                 ? "Renames the files on disk, not just the label — a torrent's "
                   + "own name is part of the data its info hash covers, so it "
                   + "cannot be changed on its own."
                 : "Available once the metadata arrives from peers.")
        }
    }

    private var speedSection: some View {
        Section("Speed limits") {
            limitField("Download", value: $downloadLimit)
            limitField("Upload", value: $uploadLimit)
            Text("Bytes per second. Zero means unlimited.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var orderSection: some View {
        Section("Download order") {
            Toggle("Download pieces in order", isOn: $isSequential)
            Toggle("Prioritise first and last pieces", isOn: $prioritisesEnds)
            Text("Turn both on to play a file before it has finished. Most media "
                 + "containers keep their index at the end, so downloading in "
                 + "order is not enough on its own — a player needs the tail as "
                 + "well as the head. Costs some speed, because pieces are no "
                 + "longer fetched rarest-first.")
                .font(.caption).foregroundStyle(.secondary)

            if !torrent.hasMetadata && prioritisesEnds {
                Label("Applied once the metadata arrives from peers.",
                      systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var queueSection: some View {
        Section("Queue") {
            Stepper("Position \(queuePosition)", value: $queuePosition, in: 0...999)
        }
    }

    private var locationSection: some View {
        Section {
            LabeledContent("Save path") {
                Text(torrent.savePath)
                    .font(.caption.monospaced())
                    .lineLimit(2).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            Button("Move to Another Folder…") { isMovingStorage = true }
        } header: {
            Text("Location")
        } footer: {
            Text("Moves the existing files and points the torrent at the new "
                 + "folder. Large downloads take a while, and the app-wide "
                 + "default is left alone.")
        }
    }

    private var maintenanceSection: some View {
        Section {
            Button("Force Recheck") {
                Task { await manager.recheck(torrent.infoHash) }
            }
            Button("Reannounce to Trackers") {
                Task { await manager.reannounce(torrent.infoHash) }
            }
        } footer: {
            Text("Rechecking verifies every piece against the torrent and can "
                 + "take a while on a large download.")
        }
    }

    private func limitField(_ label: String, value: Binding<Int>) -> some View {
        LabeledContent(label) {
            TextField("0", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
        }
    }

    private func rename() {
        guard canRename else { return }
        isNameFocused = false
        let name = trimmedName
        Task { await manager.renameContent(of: torrent.infoHash, to: name) }
    }

    private func apply() {
        Task {
            await manager.setLimits(
                for: torrent.infoHash, download: downloadLimit, upload: uploadLimit)
            await manager.setSequentialDownload(isSequential, for: torrent.infoHash)
            await manager.setFirstLastPiecePriority(prioritisesEnds, for: torrent.infoHash)
            await manager.setQueuePosition(queuePosition, for: torrent.infoHash)
            dismiss()
        }
    }
}
