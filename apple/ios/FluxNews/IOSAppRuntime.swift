import BackgroundTasks
import UIKit

@MainActor
final class IOSAppRuntime {
    static let shared = IOSAppRuntime()

    let bootstrapper: CoreBootstrapper
    let backgroundSyncCoordinator: IOSBackgroundSyncCoordinator
    let systemNotificationManager: IOSSystemNotificationManager
    let widgetSnapshotCoordinator: IOSWidgetSnapshotCoordinator

    init(
        scheduler: IOSBackgroundTaskScheduling = IOSSystemBackgroundTaskScheduler.shared,
        systemNotificationManager: IOSSystemNotificationManager? = nil
    ) {
        let bootstrapper = CoreBootstrapper()
        let backgroundSyncCoordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: scheduler
        )
        let systemNotificationManager = systemNotificationManager ?? IOSSystemNotificationManager.shared
        let widgetSnapshotCoordinator = IOSWidgetSnapshotCoordinator(bootstrapper: bootstrapper)
        self.bootstrapper = bootstrapper
        self.backgroundSyncCoordinator = backgroundSyncCoordinator
        self.systemNotificationManager = systemNotificationManager
        self.widgetSnapshotCoordinator = widgetSnapshotCoordinator

        backgroundSyncCoordinator.onSuccessfulBackgroundSync = { [weak bootstrapper, weak systemNotificationManager, weak widgetSnapshotCoordinator] metadata in
            guard let bootstrapper,
                  let core = bootstrapper.core else {
                return
            }

            await widgetSnapshotCoordinator?.refreshNow(for: core)

            guard !metadata.systemNotificationCandidates.isEmpty,
                  let systemNotificationManager else {
                return
            }
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
        _ = backgroundRegistration.register()
        IOSAppRuntime.shared.systemNotificationManager.configure()
        return true
    }
}
