import SwiftUI

@main
struct FluxNewsApp: App {
    @StateObject private var bootstrapper = CoreBootstrapper()
    @StateObject private var newsreaderStore = NewsreaderStore()

    var body: some Scene {
        WindowGroup {
            ContentView(bootstrapper: bootstrapper, newsreaderStore: newsreaderStore)
                .task {
                    await bootstrapper.start()
                    if let core = bootstrapper.core { newsreaderStore.attach(to: core) }
                }
        }
    }
}
