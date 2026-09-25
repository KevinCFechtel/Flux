import BackgroundTasks
import UIKit

enum IOSRuntimeLaunchEnvironment {
    static var isUnitTestHost: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}

@MainActor
final class IOSMediaTransferReconciliationHandoff {
    static let shared = IOSMediaTransferReconciliationHandoff()

    typealias Handler = () async -> Void

    private var handler: Handler?
    private var hasPendingRequest = false

    func install(_ handler: @escaping Handler) async {
        self.handler = handler
        guard hasPendingRequest else { return }
        hasPendingRequest = false
        await handler()
    }

    func uninstall() {
        handler = nil
    }

    func requestReconciliation() async {
        guard let handler else {
            hasPendingRequest = true
            return
        }
        await handler()
    }
}

enum IOSMediaCoreAccessState: Equatable {
    case detached
    case attached
    case suspendedForCoreReplacement
    case suspendedForLocalStateRebuild
}

/// App-scoped owner for native media execution.
///
/// D6-A intentionally owns only Core attachment/lifecycle here. AVPlayer,
/// AVAudioSession and the persistent background URLSession are added by the
/// later D6 execution packages and must remain children of this runtime.
@MainActor
final class IOSMediaRuntime {
    private(set) var core: Flux?
    private(set) var coreAccessState: IOSMediaCoreAccessState = .detached
    private(set) var lifecycleGeneration: UInt64 = 0

    let coreSessionExecutionCoordinator: IOSCoreSessionExecutionCoordinator
    let mediaTransferReconciliationHandoff: IOSMediaTransferReconciliationHandoff
    let playbackPresentationState = IOSMediaPlaybackPresentationState()
    let transferPresentationState = IOSMediaTransferPresentationState()

    init(
        coreSessionExecutionCoordinator: IOSCoreSessionExecutionCoordinator,
        mediaTransferReconciliationHandoff: IOSMediaTransferReconciliationHandoff
    ) {
        self.coreSessionExecutionCoordinator = coreSessionExecutionCoordinator
        self.mediaTransferReconciliationHandoff = mediaTransferReconciliationHandoff
    }

    func attach(to core: Flux) {
        if self.core !== core {
            lifecycleGeneration &+= 1
        }
        self.core = core
        coreAccessState = .attached
    }

    /// Runs before the app-wide Core execution gate closes. Future playback
    /// ownership uses this point to checkpoint the active medium before Core
    /// access is suspended.
    func prepareForCoreReplacement() async {
        guard core != nil else { return }
        lifecycleGeneration &+= 1
        coreAccessState = .suspendedForCoreReplacement
        mediaTransferReconciliationHandoff.uninstall()
        transferPresentationState.reset()
    }

    func resumeAfterAbortedCoreReplacement() {
        guard core != nil else { return }
        lifecycleGeneration &+= 1
        coreAccessState = .attached
    }

    /// Called only after the app-wide Core execution coordinator has quiesced.
    /// Rebuild keeps the same account/Core identity but media callbacks must not
    /// enter Core until the exclusive rebuild has finished.
    func prepareForLocalStateRebuild() {
        guard core != nil else { return }
        lifecycleGeneration &+= 1
        coreAccessState = .suspendedForLocalStateRebuild
        mediaTransferReconciliationHandoff.uninstall()
        transferPresentationState.reset()
    }

    func localStateRebuildFinished(with core: Flux) {
        attach(to: core)
    }

    func detach() {
        guard core != nil || coreAccessState != .detached else { return }
        lifecycleGeneration &+= 1
        core = nil
        coreAccessState = .detached
        mediaTransferReconciliationHandoff.uninstall()
        playbackPresentationState.reset()
        transferPresentationState.reset()
    }
}

@MainActor
final class IOSAppRuntime {
    static let shared = IOSAppRuntime()

    let bootstrapper: CoreBootstrapper
    let backgroundSyncCoordinator: IOSBackgroundSyncCoordinator
    let systemNotificationManager: IOSSystemNotificationManager
    let widgetSnapshotCoordinator: IOSWidgetSnapshotCoordinator
    let mediaTransferReconciliationHandoff: IOSMediaTransferReconciliationHandoff
    let mediaRuntime: IOSMediaRuntime

    init(
        bootstrapper: CoreBootstrapper? = nil,
        scheduler: IOSBackgroundTaskScheduling = IOSSystemBackgroundTaskScheduler.shared,
        systemNotificationManager: IOSSystemNotificationManager? = nil,
        mediaTransferReconciliationHandoff: IOSMediaTransferReconciliationHandoff? = nil
    ) {
        let bootstrapper = bootstrapper ?? CoreBootstrapper()
        let backgroundSyncCoordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: scheduler
        )
        let systemNotificationManager = systemNotificationManager ?? IOSSystemNotificationManager.shared
        let widgetSnapshotCoordinator = IOSWidgetSnapshotCoordinator(bootstrapper: bootstrapper)
        let mediaTransferReconciliationHandoff =
            mediaTransferReconciliationHandoff ?? IOSMediaTransferReconciliationHandoff.shared
        let mediaRuntime = IOSMediaRuntime(
            coreSessionExecutionCoordinator: bootstrapper.coreSessionExecutionCoordinator,
            mediaTransferReconciliationHandoff: mediaTransferReconciliationHandoff
        )
        self.bootstrapper = bootstrapper
        self.backgroundSyncCoordinator = backgroundSyncCoordinator
        self.systemNotificationManager = systemNotificationManager
        self.widgetSnapshotCoordinator = widgetSnapshotCoordinator
        self.mediaTransferReconciliationHandoff = mediaTransferReconciliationHandoff
        self.mediaRuntime = mediaRuntime

        // Media runtime lifecycle is installed before presentation exists so
        // headless/background Core bootstrap has the same single app-wide owner.
        bootstrapper.prepareForCoreReplacement = { [weak mediaRuntime] in
            await mediaRuntime?.prepareForCoreReplacement()
        }
        bootstrapper.onCoreReplacementAborted = { [weak mediaRuntime] in
            mediaRuntime?.resumeAfterAbortedCoreReplacement()
        }
        bootstrapper.prepareForLocalStateRebuild = { [weak mediaRuntime] in
            mediaRuntime?.prepareForLocalStateRebuild()
        }
        bootstrapper.onLocalStateRebuildFinished = { [weak mediaRuntime] core in
            mediaRuntime?.localStateRebuildFinished(with: core)
        }
        bootstrapper.onCoreChanged = { [weak mediaRuntime] core in
            if let core {
                mediaRuntime?.attach(to: core)
            } else {
                mediaRuntime?.detach()
            }
        }

        backgroundSyncCoordinator.onSuccessfulBackgroundSync = {
            [weak bootstrapper, weak systemNotificationManager, weak widgetSnapshotCoordinator, weak mediaTransferReconciliationHandoff]
            metadata in
            guard let bootstrapper,
                  let core = bootstrapper.core else {
                return
            }

            await widgetSnapshotCoordinator?.refreshNow(for: core)

            if !metadata.systemNotificationCandidates.isEmpty,
               let systemNotificationManager {
                await systemNotificationManager.deliver(metadata.systemNotificationCandidates) { candidateID in
                    guard let result = await bootstrapper.coreSessionExecutionCoordinator
                        .responsiveResult(
                            for: core,
                            {
                                try core.acknowledgeSystemNotification(candidateId: candidateID)
                            }
                        ) else {
                        return false
                    }
                    if case .success = result {
                        return true
                    }
                    return false
                }
            }

            await mediaTransferReconciliationHandoff?.requestReconciliation()
        }
    }
}

@MainActor
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    private lazy var backgroundRegistration = IOSBackgroundTaskRegistration(
        scheduler: IOSSystemBackgroundTaskScheduler.shared,
        identifier: IOSBackgroundRefreshConfiguration.taskIdentifier
    ) { context in
        Task { @MainActor in
            IOSAppRuntime.shared.backgroundSyncCoordinator.handle(context)
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard !IOSRuntimeLaunchEnvironment.isUnitTestHost else {
            return true
        }
        _ = backgroundRegistration.register()
        IOSAppRuntime.shared.systemNotificationManager.configure()
        return true
    }
}
