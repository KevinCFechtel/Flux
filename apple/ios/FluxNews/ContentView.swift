import SwiftUI

struct ContentView: View {
    @ObservedObject var bootstrapper: CoreBootstrapper

    var body: some View {
        NavigationStack {
            Form {
                Section("Application") {
                    LabeledContent("Name", value: "FluxNews")
                    LabeledContent("Build", value: "Native iOS development")
                }

                Section("Rust Core") {
                    LabeledContent("Status", value: bootstrapper.state.title)
                    if case let .ready(health) = bootstrapper.state {
                        LabeledContent("Smoke test", value: "runtimeHealth: \(health)")
                    }
                    if case let .error(message) = bootstrapper.state {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }

                Section("Sandbox paths") {
                    Text(bootstrapper.pathsDescription)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }

                if bootstrapper.state == .unconfigured {
                    Section {
                        Text("Set FLUX_DEV_BASE_URL and FLUX_DEV_API_KEY in the Xcode scheme to initialize the development Core.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("FluxNews")
        }
    }
}
