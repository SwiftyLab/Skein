import BackgroundTasks
import Foundation
import TorrentKit
import UIKit

/// Keeps transfers going once the app is backgrounded, within what iOS allows.
///
/// Three mechanisms, and none of them adds up to continuous downloading:
///
///  - `BGContinuedProcessingTask` is the real one. It must be started from the
///    foreground after something the user did — here, turning on the setting,
///    adding a torrent, or opening the app with downloads unfinished. The
///    system shows a Live Activity, and it keeps running
///    while backgrounded. Progress reporting is mandatory, and the system
///    reclaims tasks showing little progress first — which suits torrents,
///    since an actively-swarming download keeps running while a stalled one is
///    the first to go.
///  - `BGProcessingTask` covers the case the above structurally cannot: nobody
///    is in the app to tap anything. Delivery is opportunistic, often overnight.
///  - `beginBackgroundTask` buys a short window at suspension to save resume
///    data, without which the next launch forces a full recheck.
@MainActor
@Observable
final class BackgroundCoordinator {
    /// Derived from the bundle identifier rather than hardcoded.
    ///
    /// The Info.plist declares these as
    /// `$(PRODUCT_BUNDLE_IDENTIFIER).continued` and `.processing`, so deriving
    /// them the same way means the two can never disagree — and a mismatch is
    /// not a build error but a refused registration at launch.
    private static let bundleIdentifier =
        // Always set for an app bundle; the fallback only keeps this non-optional.
        Bundle.main.bundleIdentifier ?? "Skein"
    static var continuedIdentifier: String { "\(bundleIdentifier).continued" }
    static var processingIdentifier: String { "\(bundleIdentifier).processing" }

    /// Whether transfers should keep running in the background, on unless the
    /// user turns it off. Stored in UserDefaults so it survives relaunches.
    private(set) var keepsDownloading: Bool
    /// True from submitting the continued task until it ends, so the menu can
    /// show it and it is never submitted twice.
    private(set) var isContinuedActive = false
    /// Why the last request was refused, for the menu to show.
    private(set) var continuedError: String?

    private static let keepsDownloadingKey = "keepsDownloadingInBackground"

    @ObservationIgnored private weak var manager: TorrentManager?
    @ObservationIgnored private var suspensionTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var continuedTask: BGContinuedProcessingTask?
    /// Set once the continued task has been completed, by expiry or by the
    /// loop, which stops the loop and keeps it from being completed twice.
    @ObservationIgnored private var continuedTaskEnded = false

    init(manager: TorrentManager) {
        self.manager = manager
        keepsDownloading = UserDefaults.standard.object(forKey: Self.keepsDownloadingKey) as? Bool ?? true
    }

    /// Must run before the app finishes launching, or the scheduler rejects the
    /// identifiers later.
    func registerHandlers() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.continuedIdentifier, using: .main
        ) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            Task { await self?.runContinued(task) }
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingIdentifier, using: .main
        ) { [weak self] task in
            guard let task = task as? BGProcessingTask else { return }
            Task { await self?.runProcessing(task) }
        }
    }

    /// Turns background downloading on or off, remembering the choice.
    ///
    /// Turning it on starts the task straight away when something is
    /// downloading; turning it off ends a running one.
    func setKeepsDownloading(_ enabled: Bool) {
        keepsDownloading = enabled
        UserDefaults.standard.set(enabled, forKey: Self.keepsDownloadingKey)
        if enabled {
            startContinuedIfWanted()
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.continuedIdentifier)
            if let continuedTask { endContinued(continuedTask, success: true) }
            isContinuedActive = false
        }
    }

    /// Asks the system to keep transfers running after the app is backgrounded,
    /// when the setting is on and something is downloading.
    ///
    /// Only valid from the foreground after a user action, so callers run it
    /// when a download starts or the app is opened with downloads unfinished,
    /// never from the background.
    func startContinuedIfWanted() {
        guard keepsDownloading, !isContinuedActive,
              let manager, manager.hasActiveTransfers,
              UIApplication.shared.applicationState == .active
        else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.continuedIdentifier,
            title: "Downloading torrents",
            subtitle: "Transfers continue while you are away")
        // .queue rather than .fail: waiting its turn beats refusing outright
        // when the per-app limit is already reached.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            isContinuedActive = true
            continuedError = nil
        } catch {
            continuedError = error.localizedDescription
        }
    }

    /// Queues an opportunistic catch-up run, or withdraws a queued one when
    /// nothing is left to download, so an idle app is not woken for nothing.
    func scheduleProcessing() {
        // A stopped engine says nothing about what is left to do, so fall back
        // to queueing rather than letting the chain lapse.
        if let manager, manager.isRunning, !manager.hasActiveTransfers {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingIdentifier)
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        request.requiresNetworkConnectivity = true
        // Left false so catch-up is not restricted to charging.
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func runContinued(_ task: BGContinuedProcessingTask) async {
        // Handlers are registered before launch finishes, so the engine may
        // not be up yet. Starting it twice is a no-op.
        await manager?.start()
        continuedTask = task
        continuedTaskEnded = false
        isContinuedActive = true

        // The system ends the task on its own terms: stalled progress, the
        // user tapping Stop, or resource pressure. Completing it straight away
        // is what the system expects; the save runs under its own grace.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.endContinued(task, success: false)
                self?.beginSuspensionGrace()
            }
        }

        // Only ever grows, so a torrent that finishes keeps counting as done
        // rather than dropping out, and one added while this runs is covered.
        var tracked: Set<InfoHash> = []
        let progress = task.progress
        var reported: Int64 = 0

        // Progress is reported in bytes rather than whole percent: the system
        // reclaims a task whose progress stops moving, and on a large torrent
        // one percent can take minutes, which read as stalled and ended in
        // "Task failed" while data was still arriving.
        while !continuedTaskEnded {
            guard let manager, manager.isRunning else { break }
            tracked.formUnion(manager.torrents
                .filter { !$0.isFinished && !$0.isPaused }.map(\.infoHash))
            let statuses = manager.torrents.filter { tracked.contains($0.infoHash) }
            let remaining = statuses.filter { !$0.isFinished }
            // Done, or everything left was paused or removed: nothing to wait for.
            if remaining.allSatisfy(\.isPaused) { break }

            // Never lowered, because a removed torrent or one whose metadata
            // just arrived changes the totals, and backwards reads as stalled.
            let done = statuses.reduce(Int64(0)) { $0 + $1.totalWantedDone }
            reported = max(reported, done)
            let wanted = statuses.reduce(Int64(0)) { $0 + $1.totalWanted }
            // Kept above what is done until the end, so the system does not
            // see a finished task while pieces are still being verified.
            progress.totalUnitCount = max(wanted, reported + 1)
            progress.completedUnitCount = reported

            try? await Task.sleep(for: .seconds(2))
        }

        guard !continuedTaskEnded else { return }
        progress.completedUnitCount = progress.totalUnitCount
        await saveResumeData()
        endContinued(task, success: true)
    }

    /// Completes the task once, whichever of expiry or the loop gets there first.
    private func endContinued(_ task: BGContinuedProcessingTask, success: Bool) {
        guard !continuedTaskEnded else { return }
        continuedTaskEnded = true
        continuedTask = nil
        isContinuedActive = false
        task.setTaskCompleted(success: success)
    }

    private func runProcessing(_ task: BGProcessingTask) async {
        // A background launch may never show a view to start the engine.
        await manager?.start()
        // Rescheduled on the way out rather than up front, once it is known
        // whether anything is still unfinished. Both exits must do it: a
        // handler that forgets to reschedule silently stops the whole mechanism.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.scheduleProcessing()
                await self?.saveResumeData()
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            guard let manager, manager.isRunning else { break }
            if !manager.hasActiveTransfers { break }
            try? await Task.sleep(for: .seconds(5))
        }

        scheduleProcessing()
        await saveResumeData()
        task.setTaskCompleted(success: true)
    }

    // MARK: - Suspension

    /// Holds a short window open at backgrounding so resume data reaches disk.
    func beginSuspensionGrace() {
        guard suspensionTask == .invalid else { return }
        suspensionTask = UIApplication.shared.beginBackgroundTask(
            withName: "save-resume-data"
        ) { [weak self] in
            self?.endSuspensionGrace()
        }
        Task {
            await saveResumeData()
            endSuspensionGrace()
        }
    }

    private func endSuspensionGrace() {
        guard suspensionTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(suspensionTask)
        suspensionTask = .invalid
    }

    private func saveResumeData() async {
        await manager?.persistResumeData()
    }
}
