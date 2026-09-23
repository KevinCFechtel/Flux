import BackgroundTasks
import UIKit

@MainActor
final class IOSAppRuntime {
    static let shared = IOSAppRuntime()

    let bootstrapper: CoreBootstrapper
    let backgroundSyncCoordinator: IOSBackgroundSyncCoordinator
    let systemNotificationManager: IOSSystemNotificationManager

    init(
        scheduler: IOSBackgroundTaskScheduling = IOSSystemBackgroundTaskScheduler.shared,
        systemNotificationManager: IOSSystemNotificationManager = .shared
    ) {
        let bootstrapper = CoreBootstrapper()
        let backgroundSyncCoordinator = IOSBackgroundSyncCoordinator(
            bootstrapper: bootstrapper,
            scheduler: scheduler
        )
        self.bootstrapper = bootstrapper
        self.backgroundSyncCoordinator = backgroundSyncCoordinator
        self.systemNotificationManager = systemNotificationManager

        backgroundSyncCoordinator.onSuccessfulBackgroundSync = { [weak bootstrapper, weak systemNotificationManager] metadata in
            guard !metadata.systemNotificationCandidates.isEmpty,
                  let bootstrapper,
                  let systemNotificationManager,
                  let core = bootstrapper.core else {
                return
            }
            Task { @MainActor in
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
