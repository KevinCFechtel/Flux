import SwiftUI

struct DeveloperDiagnosticsView: View {
    @ObservedObject var bootstrapper: CoreBootstrapper

    var body: some View {
        NavigationStack {
            Form {
                Section("Rust Core") {
                    LabeledContent("Status", value: bootstrapper.state.title)
                    if case let .ready(health) = bootstrapper.state { LabeledContent("Smoke test", value: health) }
                    if case let .error(message) = bootstrapper.state { Text(message).foregroundStyle(.red) }
                }
                Section("Sandbox paths") { Text(bootstrapper.pathsDescription).font(.footnote.monospaced()).textSelection(.enabled) }
                Section("Legacy migration feasibility") {
                    ForEach(LegacyStateDiscovery.redactedSummary(bootstrapper.legacyResult).sorted(by: { $0.key < $1.key }), id: \.key) { key, value in LabeledContent(key, value: value) }
                    Text("Read-only discovery; no legacy data is imported or modified.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Developer Diagnostics")
        }
    }
}
