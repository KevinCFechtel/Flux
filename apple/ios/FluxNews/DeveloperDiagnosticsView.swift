import SwiftUI

struct DeveloperDiagnosticsView: View {
    @ObservedObject var bootstrapper: CoreBootstrapper
    @State private var legacyResult = LegacyStateDiscovery.probe()
    @State private var imageMode = IOSArticleImageABDiagnostic.shared.mode

    var body: some View {
        NavigationStack {
            Form {
                Section("Rust Core") {
                    LabeledContent("Status", value: bootstrapper.state.title)
                    if case let .ready(health) = bootstrapper.state { LabeledContent("Smoke test", value: health) }
                    if case let .recoverableError(message) = bootstrapper.state { Text(message).foregroundStyle(.red) }
                }
                Section("Sandbox paths") { Text(bootstrapper.pathsDescription).font(.footnote.monospaced()).textSelection(.enabled) }
                Section("Legacy migration feasibility") {
                    ForEach(LegacyStateDiscovery.redactedSummary(legacyResult).sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledContent(localizedDiagnosticLabel(key), value: value)
                    }
                    Text("Read-only discovery; no legacy data is imported or modified.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Visual Portrait Image A/B") {
                    Picker("Image source", selection: $imageMode) {
                        ForEach(IOSArticleImageABDiagnostic.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .onChange(of: imageMode) { _, mode in
                        IOSArticleImageABDiagnostic.shared.select(mode)
                    }
                    Text(IOSArticleImageABDiagnostic.shared.preparationDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Only Visual Portrait is supported. Other layouts keep normal images and are not a comparison.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
#if DEBUG || FLUX_PERFORMANCE_DIAGNOSTICS
                Section("Timeline Performance") {
                    Button("Reset Timeline Metrics") {
                        Task { await IOSUIKitTimelinePerformanceDiagnostics.resetAndPrint() }
                    }
                    Button("Print Timeline Metrics") {
                        Task { await IOSUIKitTimelinePerformanceDiagnostics.printSnapshot() }
                    }
                }
#endif
            }
            .navigationTitle("Developer Diagnostics")
        }
    }

    private func localizedDiagnosticLabel(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}
