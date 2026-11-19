import SwiftUI
import TorrentKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Shows the diagnostics report so the user can copy or share it when
/// downloads stall, e.g. to attach to a GitHub issue or a support email.
struct DiagnosticsView: View {
    @Environment(TorrentManager.self) private var manager

    @State private var report: String?
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text(Self.summary)
                Text(Self.privacyNote)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Section("Report") {
                if let report {
                    Text(report)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    guard let report else { return }
                    copy(report)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(report == nil)
                if let report {
                    ShareLink(item: report, subject: Text("Skein diagnostics")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private static let summary = """
        How Skein sees your network: the interfaces and routes the engine found, \
        which ones it can reach trackers from, its listen sockets, each tracker's \
        result per interface and recent engine events.
        """

    private static let privacyNote = """
        It includes your device's IP addresses. Torrent names and tracker passkeys \
        are left out. Add a torrent that won't download and wait a minute before \
        copying, so the report shows what happened.
        """

    private func load() async {
        copied = false
        report = await manager.diagnosticsReport()
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
