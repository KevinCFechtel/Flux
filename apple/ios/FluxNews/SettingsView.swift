import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var store: NewsreaderStore
    @ObservedObject var bootstrapper: CoreBootstrapper
    @ObservedObject var articleListActionPreferences: IOSArticleListActionPreferences
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
                    ArticlesSettingsView(store: store, bootstrapper: bootstrapper)
                } label: {
                    Label("Articles", systemImage: "doc.text")
                }
                NavigationLink {
                    ArticleListActionsSettingsView(
                        preferences: articleListActionPreferences
                    )
                } label: {
                    Label("Action Bar", systemImage: "rectangle.bottomthird.inset.filled")
                }
                NavigationLink {
                    NavigationSettingsView(store: store)
                } label: {
                    Label("Navigation", systemImage: "sidebar.leading")
                }
                NavigationLink {
                    IOSMediaSettingsView(
                        bootstrapper: bootstrapper,
                        onPolicyChanged: {
                            await IOSAppRuntime.shared
                                .mediaTransferReconciliationHandoff
                                .requestReconciliation()
                        }
                    )
                } label: {
                    Label("Media", systemImage: "headphones")
                }
                NavigationLink {
                    BackgroundSyncSettingsView(
                        coordinator: IOSAppRuntime.shared.backgroundSyncCoordinator
                    )
                } label: {
                    Label("Background Sync", systemImage: "arrow.triangle.2.circlepath")
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
