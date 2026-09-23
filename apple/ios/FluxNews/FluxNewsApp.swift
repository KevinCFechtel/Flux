import SwiftUI

enum IOSSceneOwnershipPolicy {
    // Core/session and mutation coordination are intentionally single-window until
    // a future multi-scene coordinator can own them independently of presentation.
    static let supportsMultipleScenes = false
}

final class FluxNewsAppBundleMarker {}

@main
struct FluxNewsApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bootstrapper = CoreBootstrapper()
    @State private var newsreaderStore = NewsreaderStore()

    var body: some Scene {
        WindowGroup {
            ContentView(bootstrapper: bootstrapper, newsreaderStore: newsreaderStore)
                .tint(Color("FluxAccent"))
                .task {
                    bootstrapper.prepareForCoreReplacement = {
                        await newsreaderStore.quiesceManualSyncForCoreReplacement()
                    }
                    bootstrapper.onCoreReplacementAborted = {
                        newsreaderStore.resumeManualSyncAfterAbortedCoreReplacement()
                    }
                    bootstrapper.onCoreChanged = { core in
                        if let core {
                            newsreaderStore.attach(
                                to: core,
                                coreSessionExecutionCoordinator: bootstrapper.coreSessionExecutionCoordinator
                            )
                        } else {
                            newsreaderStore.detach()
                        }
                    }
                    await bootstrapper.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        newsreaderStore.flushScrolloverPersistenceForLifecycle()
                    }
                }
        }
    }
}
