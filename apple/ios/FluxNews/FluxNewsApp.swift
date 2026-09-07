import SwiftUI

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
                    bootstrapper.onCoreChanged = { core in
                        if let core { newsreaderStore.attach(to: core) }
                        else { newsreaderStore.detach() }
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
