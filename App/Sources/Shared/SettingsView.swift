import SwiftUI
import TorrentKit

/// Network, privacy and bandwidth settings.
struct SettingsView: View {
    @Environment(TorrentManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    @State private var configuration = SessionConfiguration()
    @State private var blockedRanges = ""
    @State private var applyError: String?

    var body: some View {
        Form {
            Section("Bandwidth") {
                rateField("Download limit", value: $configuration.downloadRateLimit)
                rateField("Upload limit", value: $configuration.uploadRateLimit)
                Text("Zero means unlimited.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Activity") {
                countField("Max active downloads", value: $configuration.maxActiveDownloads)
                countField("Max active seeds", value: $configuration.maxActiveSeeds)
                countField("Max connections", value: $configuration.maxConnections)
                Text("Use −1 to leave the engine's defaults alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Peer discovery") {
                Toggle("DHT", isOn: $configuration.isDHTEnabled)
                Toggle("Local peer discovery", isOn: $configuration.isLocalDiscoveryEnabled)
                Toggle("UPnP", isOn: $configuration.isUPnPEnabled)
                Toggle("NAT-PMP", isOn: $configuration.isNATPMPEnabled)
                Toggle("Peer exchange", isOn: $configuration.isPEXEnabled)
                Text("Peer exchange only takes effect after restarting the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Encryption") {
                Picker("Protocol encryption", selection: $configuration.encryption) {
                    ForEach(EncryptionPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                Text("Obfuscates the peer protocol against traffic shaping. It is not a privacy guarantee.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Proxy") {
                Picker("Type", selection: $configuration.proxy.kind) {
                    ForEach(ProxyKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                if configuration.proxy.kind != .none {
                    TextField("Host", text: $configuration.proxy.host)
                    TextField("Port", value: $configuration.proxy.port, format: .number)
                    TextField("Username", text: $configuration.proxy.username)
                    SecureField("Password", text: $configuration.proxy.password)
                    Toggle("Proxy peer connections",
                           isOn: $configuration.proxy.proxiesPeerConnections)
                    Toggle("Resolve hostnames at proxy",
                           isOn: $configuration.proxy.proxiesHostnames)
                    Text("Without these two, the proxy hides announces but not which peers you contact, and DNS still resolves locally.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Blocked addresses") {
                TextField("One CIDR range per line", text: $blockedRanges, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.caption.monospaced())
            }

            if let applyError {
                Section {
                    Label(applyError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") { apply() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func rateField(_ label: String, value: Binding<Int>) -> some View {
        LabeledContent(label) {
            HStack {
                TextField("0", value: value, format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Text("B/s").foregroundStyle(.secondary)
            }
        }
    }

    private func countField(_ label: String, value: Binding<Int>) -> some View {
        LabeledContent(label) {
            TextField("-1", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
    }

    private func apply() {
        let ranges = blockedRanges
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Task {
            applyError = await manager.apply(configuration, blockedRanges: ranges)
            if applyError == nil { dismiss() }
        }
    }
}
