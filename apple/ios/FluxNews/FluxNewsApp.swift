import SwiftUI
import UIKit

enum IOSSceneOwnershipPolicy {
    // Core/session and mutation coordination are intentionally single-window until
    // a future multi-scene coordinator can own them independently of presentation.
    static let supportsMultipleScenes = false
}

final class FluxNewsAppBundleMarker {}

@MainActor
@main
struct FluxNewsApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bootstrapper = IOSAppRuntime.shared.bootstrapper
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
                    if let core = await bootstrapper.ensureStarted(),
                       newsreaderStore.core !== core {
                        newsreaderStore.attach(
                            to: core,
                            coreSessionExecutionCoordinator: bootstrapper.coreSessionExecutionCoordinator
                        )
                    }
                    await IOSAppRuntime.shared.backgroundSyncCoordinator.refreshScheduling()
                    IOSAppRuntime.shared.backgroundSyncCoordinator.resumeIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            if let core = await bootstrapper.ensureStarted(),
                               newsreaderStore.core !== core {
                                newsreaderStore.attach(
                                    to: core,
                                    coreSessionExecutionCoordinator: bootstrapper.coreSessionExecutionCoordinator
                                )
                            }
                            IOSAppRuntime.shared.backgroundSyncCoordinator.resumeIfNeeded()
                        }
                    } else {
                        newsreaderStore.flushScrolloverPersistenceForLifecycle()
                    }
                }
        }
    }
}
