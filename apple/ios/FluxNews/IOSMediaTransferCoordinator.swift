import Foundation
import OSLog

enum IOSMediaBackgroundTransferConfiguration {
    static var sessionIdentifier: String {
        let bundleID = Bundle.main.bundleIdentifier
            ?? "dev.kevincfechtel.fluxNews.nativeDev"
        return "\(bundleID).mediaTransfers.v1"
    }

    static func makeSessionConfiguration(
        identifier: String = sessionIdentifier
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return configuration
    }
}

@MainActor
final class IOSMediaTransferCoordinator: NSObject {
    private let bootstrapper: CoreBootstrapper
    private let coreSessionExecutionCoordinator: IOSCoreSessionExecutionCoordinator
    private let presentationState: IOSMediaTransferPresentationState
    private let handoff: IOSMediaTransferReconciliationHandoff
    private let sessionIdentifier: String
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.kevincfechtel.fluxNews",
        category: "media-transfer"
    )

    private var core: Flux?
    private var lifecycleGeneration: UInt64 = 0
    private var backgroundEventsCompletionHandler: (() -> Void)?
    private var backgroundEventsFinished = false

    private lazy var session: URLSession = {
        URLSession(
            configuration: IOSMediaBackgroundTransferConfiguration.makeSessionConfiguration(
                identifier: sessionIdentifier
            ),
            delegate: self,
            delegateQueue: nil
        )
    }()

    init(
        bootstrapper: CoreBootstrapper,
        coreSessionExecutionCoordinator: IOSCoreSessionExecutionCoordinator,
        presentationState: IOSMediaTransferPresentationState,
        handoff: IOSMediaTransferReconciliationHandoff,
        sessionIdentifier: String = IOSMediaBackgroundTransferConfiguration.sessionIdentifier
    ) {
        self.bootstrapper = bootstrapper
        self.coreSessionExecutionCoordinator = coreSessionExecutionCoordinator
        self.presentationState = presentationState
        self.handoff = handoff
        self.sessionIdentifier = sessionIdentifier
        super.init()
    }

    func attach(to core: Flux, generation: UInt64) {
        self.core = core
        lifecycleGeneration = generation

        Task { @MainActor [weak self, weak core] in
            guard let self,
                  let core,
                  self.core === core,
                  self.lifecycleGeneration == generation else {
                return
            }

            await handoff.install { [weak self, weak core] in
                guard let self,
                      let core,
                      self.core === core,
                      self.lifecycleGeneration == generation else {
                    return
                }
                await self.reconcile()
            }
        }
    }

    func detach(generation: UInt64) {
        lifecycleGeneration = generation
        core = nil
        handoff.uninstall()
        presentationState.reset()
    }

    func suspendForCoreLifecycle(generation: UInt64) {
        lifecycleGeneration = generation
        handoff.uninstall()
        presentationState.reset()
    }

    /// D6-B reconciliation entry point. The persistent URLSession owns native
    /// task execution; this method is the only D5 -> D6 handoff target.
    ///
    /// The first D6-B slice establishes session/core ownership and validates
    /// that Core work enters through the app-wide execution gate. Task/file
    /// comparison and transfer creation are added in the next reconciliation
    /// slice.
    func reconcile() async {
        guard let core else { return }
        guard let result = await coreSessionExecutionCoordinator.responsiveResult(
            for: core,
            {
                (
                    try core.coreSettings(),
                    try core.downloadsRequiringTransfer(),
                    try core.downloadsRequiringDeletion()
                )
            }
        ) else {
            return
        }

        switch result {
        case let .success((settings, transfers, deletions)):
            applyNetworkPolicy(settings.downloadNetworkPolicy)
            logger.debug(
                "media reconciliation admitted requested=\(transfers.count, privacy: .public) deletions=\(deletions.count, privacy: .public)"
            )
        case let .failure(error):
            logger.error(
                "media reconciliation Core query failed: \(String(reflecting: error), privacy: .private)"
            )
        }
    }

    /// Called from UIApplicationDelegate when iOS relaunches or wakes the app
    /// to deliver events for this exact background session.
    func handleBackgroundEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard identifier == sessionIdentifier else {
            return false
        }

        // Materializing the session with the same stable identifier reconnects
        // this delegate to OS-owned tasks from the previous process.
        _ = session
        backgroundEventsCompletionHandler = completionHandler
        backgroundEventsFinished = false

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await bootstrapper.ensureStarted()
            await reconcile()
            finishBackgroundEventsIfPossible()
        }
        return true
    }

    private func applyNetworkPolicy(_ policy: DownloadNetworkPolicy) {
        // Existing background tasks retain the constraints with which they were
        // created. The next D6-B slice applies these values when creating each
        // task/session request and reconciles policy changes.
        _ = policy
    }

    private func finishBackgroundEventsIfPossible() {
        guard backgroundEventsFinished,
              let completionHandler = backgroundEventsCompletionHandler else {
            return
        }
        backgroundEventsCompletionHandler = nil
        completionHandler()
    }
}

extension IOSMediaTransferCoordinator: URLSessionDelegate {
    nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            backgroundEventsFinished = true
            finishBackgroundEventsIfPossible()
        }
    }
}
