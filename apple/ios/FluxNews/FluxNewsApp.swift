import SwiftUI

@main
struct FluxNewsApp: App {
    @StateObject private var bootstrapper = CoreBootstrapper()
    @StateObject private var newsreaderStore = NewsreaderStore()

    var body: some Scene {
        WindowGroup {
            ContentView(bootstrapper: bootstrapper, newsreaderStore: newsreaderStore)
                .task {
                    bootstrapper.onCoreChanged = { core in
                        if let core { newsreaderStore.attach(to: core) }
                        else { newsreaderStore.detach() }
                    }
                    await bootstrapper.start()
                }
        }
    }
}
