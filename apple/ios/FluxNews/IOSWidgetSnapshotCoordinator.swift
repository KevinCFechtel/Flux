import Foundation
import OSLog

@MainActor
final class IOSWidgetSnapshotCoordinator {
    private let bootstrapper: CoreBootstrapper
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.kevincfechtel.fluxNews",
        category: "widget_snapshot"
    )
    private var eventSubscription: EventSubscription?
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(bootstrapper: CoreBootstrapper) {
        self.bootstrapper = bootstrapper
    }

    func attach(to core: Flux) {
        generation &+= 1
        let current = generation
        eventSubscription = nil
        do {
            eventSubscription = try core.subscribeEvents(
                listener: IOSWidgetSnapshotEventListener(
                    coordinator: self,
                    core: core,
                    generation: current
                )
            )
        } catch {
            logger.error(
                "Widget event subscription failed error=\(String(reflecting: error), privacy: .private)"
            )
        }
        refresh(for: core, generation: current)
    }

    func detach() {
        generation &+= 1
        eventSubscription = nil
        refreshTask?.cancel()
        refreshTask = nil
        do {
            let store = try WidgetSnapshotStore(diagnostics: WidgetSnapshotDiagnostics.logger)
            try store.invalidate()
            WidgetTimelineReloader.reloadAll()
        } catch {
            logger.error(
                "Widget snapshot invalidation failed error=\(String(reflecting: error), privacy: .private)"
            )
        }
    }

    func handle(event: CoreEvent, core: Flux, generation: UInt64) {
        guard generation == self.generation else { return }
        switch event {
        case .articleReadStateChanged, .articleStarredStateChanged, .syncCompleted:
            refresh(for: core, generation: generation)
        default:
            break
        }
    }

    func refreshNow(for core: Flux) async {
        let current = generation
        await performRefresh(for: core, generation: current)
    }

    private func refresh(for core: Flux, generation: UInt64) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(for: core, generation: generation)
        }
    }

    private func performRefresh(for core: Flux, generation: UInt64) async {
        guard generation == self.generation else { return }
        let sessionCoordinator = bootstrapper.coreSessionExecutionCoordinator
        guard let result = await sessionCoordinator.responsiveResult(
            for: core,
            {
                let store = try WidgetSnapshotStore(diagnostics: WidgetSnapshotDiagnostics.logger)
                try WidgetSnapshotWriter.refresh(core: core, store: store)
            }
        ) else {
            return
        }
        guard generation == self.generation else { return }
        switch result {
        case .success:
            WidgetTimelineReloader.reloadAll()
        case let .failure(error):
            logger.error(
                "Widget snapshot refresh failed error=\(String(reflecting: error), privacy: .private)"
            )
        }
    }
}

private final class IOSWidgetSnapshotEventListener: EventListener, @unchecked Sendable {
    weak var coordinator: IOSWidgetSnapshotCoordinator?
    let core: Flux
    let generation: UInt64

    init(
        coordinator: IOSWidgetSnapshotCoordinator,
        core: Flux,
        generation: UInt64
    ) {
        self.coordinator = coordinator
        self.core = core
        self.generation = generation
    }

    func onEvent(event: CoreEvent) {
        Task { @MainActor [weak coordinator] in
            coordinator?.handle(event: event, core: core, generation: generation)
        }
    }
}
