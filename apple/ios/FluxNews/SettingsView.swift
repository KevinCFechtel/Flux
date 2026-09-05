import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var store: NewsreaderStore
    @ObservedObject var bootstrapper: CoreBootstrapper
    let onDiagnostics: () -> Void

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    AccountConfigurationView(bootstrapper: bootstrapper, allowsRemoval: true, embedded: true)
                } label: {
                    Label("Account", systemImage: "person.crop.circle")
                }
                NavigationLink {
                    ArticlesSettingsView(store: store)
                } label: {
                    Label("Articles", systemImage: "doc.text")
                }
                NavigationLink {
                    NavigationSettingsView(store: store)
                } label: {
                    Label("Navigation", systemImage: "sidebar.leading")
                }
                Button { onDiagnostics() } label: {
                    Label("Developer Diagnostics", systemImage: "info.circle")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
