import SwiftUI

@main
struct FluxNewsApp: App {
    @StateObject private var bootstrapper = CoreBootstrapper()

    var body: some Scene {
        WindowGroup {
            ContentView(bootstrapper: bootstrapper)
                .task { await bootstrapper.start() }
        }
    }
}
