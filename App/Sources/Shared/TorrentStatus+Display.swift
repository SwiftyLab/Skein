import SwiftUI
import TorrentKit

extension TorrentStatus {
    /// A short description of what this torrent is doing, for the UI.
    var statusText: String {
        if let errorMessage { return errorMessage }
        if isPaused { return "Paused" }
        switch state {
        case .checkingResumeData: return "Checking resume data"
        case .checkingFiles: return "Checking files"
        case .downloadingMetadata: return "Fetching metadata"
        case .downloading: return "Downloading"
        case .finished: return "Finished"
        case .seeding: return "Seeding"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        if errorMessage != nil { return "exclamationmark.triangle.fill" }
        if isPaused { return "pause.circle.fill" }
        switch state {
        case .seeding, .finished: return "arrow.up.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .downloadingMetadata: return "magnifyingglass.circle.fill"
        case .checkingFiles, .checkingResumeData: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        if errorMessage != nil { return .orange }
        if isPaused { return .secondary }
        switch state {
        case .seeding, .finished: return .green
        case .downloading: return .accentColor
        default: return .secondary
        }
    }

    /// Which sidebar filters this torrent belongs to.
    func matches(_ filter: TorrentFilter) -> Bool {
        switch filter {
        case .all: return true
        case .downloading: return !isPaused && !isFinished
        case .seeding: return isSeeding && !isPaused
        case .paused: return isPaused
        case .finished: return isFinished
        }
    }
}

/// Sidebar categories.
enum TorrentFilter: String, CaseIterable, Identifiable, Hashable {
    case all = "All"
    case downloading = "Downloading"
    case seeding = "Seeding"
    case paused = "Paused"
    case finished = "Finished"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .seeding: return "arrow.up.circle"
        case .paused: return "pause.circle"
        case .finished: return "checkmark.circle"
        }
    }
}
