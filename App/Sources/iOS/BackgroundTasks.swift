import BackgroundTasks
import Foundation
import TorrentKit
import UIKit

/// Keeps transfers going once the app is backgrounded, within what iOS allows.
///
/// Three mechanisms, and none of them adds up to continuous downloading:
///
///  - `BGContinuedProcessingTask` is the real one. It must be started by a
///    deliberate tap, the system shows a Live Activity, and it keeps running
///    while backgrounded. Progress reporting is mandatory, and the system
///    reclaims tasks showing little progress first — which suits torrents,
///    since an actively-swarming download keeps running while a stalled one is
///    the first to go.
///  - `BGProcessingTask` covers the case the above structurally cannot: nobody
///    is in the app to tap anything. Delivery is opportunistic, often overnight.
///  - `beginBackgroundTask` buys a short window at suspension to save resume
///    data, without which the next launch forces a full recheck.
@MainActor
final class BackgroundCoordinator {
    /// Derived from the bundle identifier rather than hardcoded.
    ///
    /// The Info.plist declares these as
    /// `$(PRODUCT_BUNDLE_IDENTIFIER).continued` and `.processing`, so deriving
    /// them the same way means the two can never disagree — and a mismatch is
    /// not a build error but a refused registration at launch.
    private static let bundleIdentifier =
        Bundle.main.bundleIdentifier ?? "dev.soumyamahunt.skein"
    static var continuedIdentifier: String { "\(bundleIdentifier).continued" }
    static var processingIdentifier: String { "\(bundleIdentifier).processing" }

    private weak var manager: TorrentManager?
    private var suspensionTask: UIBackgroundTaskIdentifier = .invalid

    init(manager: TorrentManager) {
        self.manager = manager
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

    /// Asks the system to keep transfers running after the app is backgrounded.
    ///
    /// Only valid from the foreground in response to a user action, which is
    /// why this is wired to an explicit button rather than called on launch.
    /// Static because the view issuing it has no handle on the coordinator.
    static func requestContinuedProcessing() throws {
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.continuedIdentifier,
            title: "Downloading torrents",
            subtitle: "Transfers continue while you are away")
        // .queue rather than .fail: waiting its turn beats refusing outright
        // when the per-app limit is already reached.
        request.strategy = .queue
        try BGTaskScheduler.shared.submit(request)
    }

    /// Queues an opportunistic catch-up run.
    func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        request.requiresNetworkConnectivity = true
        // Left false so catch-up is not restricted to charging.
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func runContinued(_ task: BGContinuedProcessingTask) async {
        let progress = task.progress
        progress.totalUnitCount = 100

        task.expirationHandler = { [weak self] in
            Task { @MainActor in await self?.saveResumeData() }
        }

        // Reporting real progress is not cosmetic: the system reclaims tasks
        // that appear stalled, so a healthy download has to look healthy.
        while !Task.isCancelled {
            guard let manager, manager.isRunning else { break }
            let active = manager.torrents.filter { !$0.isFinished && !$0.isPaused }
            guard !active.isEmpty else { break }

            let completed = active.reduce(0.0) { $0 + $1.progress } / Double(active.count)
            progress.completedUnitCount = Int64(completed * 100)
            if completed >= 1.0 { break }

            try? await Task.sleep(for: .seconds(2))
        }

        await saveResumeData()
        task.setTaskCompleted(success: true)
    }

    private func runProcessing(_ task: BGProcessingTask) async {
        // Queue the next one immediately: a handler that forgets to reschedule
        // silently stops the whole mechanism.
        scheduleProcessing()

        task.expirationHandler = { [weak self] in
            Task { @MainActor in await self?.saveResumeData() }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            guard let manager, manager.isRunning else { break }
            if manager.torrents.allSatisfy({ $0.isFinished || $0.isPaused }) { break }
            try? await Task.sleep(for: .seconds(5))
        }

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
