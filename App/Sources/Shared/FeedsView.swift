import SwiftUI
import TorrentFeeds

/// Manage RSS subscriptions and their auto-download rules.
struct FeedsView: View {
    @Environment(FeedCoordinator.self) private var coordinator

    @State private var isShowingAddFeed = false
    @State private var editingFeed: Feed?

    var body: some View {
        List {
            if coordinator.feeds.isEmpty {
                ContentUnavailableView {
                    Label("No Feeds", systemImage: "dot.radiowaves.up.forward")
                } description: {
                    Text("Subscribe to an RSS feed to add matching torrents automatically.")
                }
            }
            ForEach(coordinator.feeds) { feed in
                Button { editingFeed = feed } label: { FeedRow(feed: feed) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await coordinator.remove(feed) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            Task { await coordinator.checkNow(feed) }
                        } label: {
                            Label("Check Now", systemImage: "arrow.clockwise")
                        }
                        .tint(.blue)
                    }
            }
        }
        .navigationTitle("Feeds")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isShowingAddFeed = true } label: {
                    Label("Add Feed", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingAddFeed) { FeedEditor(feed: nil) }
        .sheet(item: $editingFeed) { feed in FeedEditor(feed: feed) }
    }
}

private struct FeedRow: View {
    let feed: Feed

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feed.title).font(.headline)
                Spacer()
                if !feed.isEnabled {
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(feed.url.absoluteString)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 10) {
                Text("\(feed.rules.count) rule\(feed.rules.count == 1 ? "" : "s")")
                if let lastChecked = feed.lastChecked {
                    Text("Checked \(lastChecked.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)

            if let error = feed.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Add or edit a feed and its rules.
private struct FeedEditor: View {
    @Environment(FeedCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    let feed: Feed?

    @State private var title = ""
    @State private var urlText = ""
    @State private var refreshMinutes = 30
    @State private var isEnabled = true
    @State private var includes = ""
    @State private var excludes = ""
    @State private var usesRegex = false

    private var isValid: Bool {
        !title.isEmpty && URL(string: urlText)?.scheme?.hasPrefix("http") == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Feed") {
                    TextField("Title", text: $title)
                    TextField("https://example.com/rss", text: $urlText)
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Stepper("Check every \(refreshMinutes) min",
                            value: $refreshMinutes, in: 5...1_440, step: 5)
                    Toggle("Enabled", isOn: $isEnabled)
                }

                Section("Match rules") {
                    TextField("Include (one per line)", text: $includes, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Exclude (one per line)", text: $excludes, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("Treat patterns as regular expressions", isOn: $usesRegex)
                    Text("Leave include empty to accept everything. Exclude always wins.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(feed == nil ? "Add Feed" : "Edit Feed")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 460)
        #endif
    }

    private func load() {
        guard let feed else { return }
        title = feed.title
        urlText = feed.url.absoluteString
        refreshMinutes = Int(feed.refreshInterval / 60)
        isEnabled = feed.isEnabled
        if let rule = feed.rules.first {
            includes = rule.includes.joined(separator: "\n")
            excludes = rule.excludes.joined(separator: "\n")
            usesRegex = rule.usesRegularExpressions
        }
    }

    private func save() {
        guard let url = URL(string: urlText) else { return }
        func lines(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        let rule = FeedRule(
            id: feed?.rules.first?.id ?? UUID(),
            name: "Rule",
            includes: lines(includes),
            excludes: lines(excludes),
            usesRegularExpressions: usesRegex)

        let updated = Feed(
            id: feed?.id ?? UUID(),
            title: title,
            url: url,
            refreshInterval: TimeInterval(refreshMinutes * 60),
            isEnabled: isEnabled,
            rules: [rule],
            lastChecked: feed?.lastChecked)

        Task {
            await coordinator.save(updated)
            dismiss()
        }
    }
}
