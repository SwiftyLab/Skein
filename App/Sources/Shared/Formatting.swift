import Foundation

/// Shared value formatting, so byte counts and rates read the same everywhere.
public enum Format {
    /// Built per call rather than cached: `ByteCountFormatter` is not
    /// `Sendable`, so a shared instance would be mutable state across actors,
    /// and formatting a byte count is cheap enough not to warrant the risk.
    public static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, count))
    }

    /// A transfer rate, or an em dash when idle — "0 KB/s" on every stopped row
    /// is noise.
    public static func rate(_ bytesPerSecond: Int) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return "\(bytes(Int64(bytesPerSecond)))/s"
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))%"
    }

    /// Coarse by design: second-level precision on a multi-hour download is
    /// false confidence.
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3_600)
            let minutes = Int((seconds - Double(hours) * 3_600) / 60)
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(Int(seconds / 86_400))d"
    }
}
