import SwiftUI

struct ContentView: View {
    @ObservedObject var bootstrapper: CoreBootstrapper
    @ObservedObject var newsreaderStore: NewsreaderStore

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

                Section("Legacy migration feasibility") {
                    ForEach(LegacyStateDiscovery.redactedSummary(bootstrapper.legacyResult).sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledContent(key, value: value)
                    }
                    Text("This is read-only discovery only. No legacy data is imported or modified.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
