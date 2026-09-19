import UniformTypeIdentifiers
import UIKit

/// Accepts magnet links and `.torrent` files shared from other apps.
///
/// The extension deliberately does no networking. It hands the item to the main
/// app through the shared container and opens it, because running a libtorrent
/// session inside an extension would fight the much tighter memory limit and
/// die mid-transfer.
final class ShareViewController: UIViewController {

    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        Task { await handleSharedItem() }
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        statusLabel.text = "Adding to Skein…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }

    private func handleSharedItem() async {
        guard let item = (extensionContext?.inputItems as? [NSExtensionItem])?.first,
              let provider = item.attachments?.first
        else {
            return finish(message: "Nothing to add.")
        }

        if let url = await loadURL(from: provider) {
            if url.scheme == "magnet" {
                open(url)
                return finish(message: nil)
            }
            if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                await copyIntoSharedContainer(url)
                return
            }
        }

        // Safari often shares a magnet as plain text rather than a URL.
        if let text = await loadText(from: provider),
           text.hasPrefix("magnet:"), let url = URL(string: text) {
            open(url)
            return finish(message: nil)
        }

        finish(message: "That is not a torrent or a magnet link.")
    }

    private func copyIntoSharedContainer(_ url: URL) async {
        let group = Self.appGroup
        guard !group.isEmpty,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group)
        else {
            // Magnet links still work; only the file handoff needs the group.
            return finish(message:
                "This build cannot receive files. Share a magnet link instead.")
        }

        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: inbox, withIntermediateDirectories: true)
            let destination = inbox.appendingPathComponent(
                "\(UUID().uuidString)-\(url.lastPathComponent)")
            // Shared files are security-scoped, and access has to be held for
            // the copy itself.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: destination)

            // The app picks this up on next launch or foreground.
            open(URL(string: "skein://inbox")!)
            finish(message: nil)
        } catch {
            finish(message: "Could not hand that file to Skein.")
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        else { return nil }
        return try? await provider.loadItem(
            forTypeIdentifier: UTType.url.identifier) as? URL
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        else { return nil }
        return try? await provider.loadItem(
            forTypeIdentifier: UTType.plainText.identifier) as? String
    }

    /// Extensions cannot call `UIApplication.shared.open`, so the responder
    /// chain is walked to find something that can.
    private func open(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url)
                return
            }
            responder = current.next
        }
    }

    private func finish(message: String?) {
        if let message {
            statusLabel.text = message
            // Left on screen briefly so the reason is readable.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Read from the Info.plist, which Project.swift fills from one value, so
    /// the app and the extension cannot disagree about the container. Empty
    /// when app groups are not enabled for this build.
    static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "SKAppGroup") as? String ?? ""
    }
}
