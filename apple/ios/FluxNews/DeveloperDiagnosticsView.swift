import SwiftUI

struct DeveloperDiagnosticsView: View {
    @ObservedObject var bootstrapper: CoreBootstrapper
    @State private var legacyResult = LegacyStateDiscovery.probe()
    @State private var frameHeadroom = IOSUIKitTimelineFrameHeadroomDiagnostics.formattedSnapshot()

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
                // TEMPORARY PERFORMANCE DIAGNOSTIC — MUST NOT SHIP. Release
                // builds must reach this to record both scroll-edge arms in one
                // session on one device.
                Section("Timeline Frame Headroom (diagnostic)") {
                    Text(frameHeadroom).font(.footnote.monospaced()).textSelection(.enabled)
                    Button("Refresh Frame Headroom") {
                        frameHeadroom = IOSUIKitTimelineFrameHeadroomDiagnostics.formattedSnapshot()
                    }
                    Button("Reset Frame Headroom") {
                        IOSUIKitTimelineFrameHeadroomDiagnostics.recorder.reset()
                        frameHeadroom = IOSUIKitTimelineFrameHeadroomDiagnostics.formattedSnapshot()
                    }
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
