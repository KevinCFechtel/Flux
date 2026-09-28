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
                    DownloadedDataSettingsView(
                        bootstrapper: bootstrapper,
                        transferCoordinator: IOSAppRuntime.shared.mediaRuntime.transferCoordinator,
                        onDeletionRequested: {
                            await IOSAppRuntime.shared
                                .mediaTransferReconciliationHandoff
                                .requestReconciliation()
                        }
                    )
                } label: {
                    Label("Downloaded Data", systemImage: "internaldrive")
                }
                NavigationLink {
                    BackgroundSyncSettingsView(
                        coordinator: IOSAppRuntime.shared.backgroundSyncCoordinator
                    )
                } label: {
                    Label("Background Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink {
                    AboutSettingsView()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
                Button { onDiagnostics() } label: {
                    Label("Developer Diagnostics", systemImage: "stethoscope")
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


enum IOSAboutInformation {
    static let fluxNewsRepositoryURL =
        URL(string: "https://github.com/KevinCFechtel/FluxNews")!
    static let fluxRepositoryURL =
        URL(string: "https://github.com/KevinCFechtel/Flux")!
    static let minifluxProjectURL =
        URL(string: "https://miniflux.app")!
    static let licenseURL =
        URL(string: "https://github.com/KevinCFechtel/FluxNews/blob/main/LICENSE")!

    static func version(from infoDictionary: [String: Any]) -> String {
        nonEmptyString(
            infoDictionary["CFBundleShortVersionString"]
        ) ?? String(localized: "Unknown")
    }

    static func build(from infoDictionary: [String: Any]) -> String {
        nonEmptyString(
            infoDictionary["CFBundleVersion"]
        ) ?? String(localized: "Unknown")
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AboutSettingsView: View {
    private let infoDictionary: [String: Any]

    init(bundle: Bundle = .main) {
        infoDictionary = bundle.infoDictionary ?? [:]
    }

    var body: some View {
        List {
            Section {
                LabeledContent(
                    "Version",
                    value: IOSAboutInformation.version(from: infoDictionary)
                )
                LabeledContent(
                    "Build",
                    value: IOSAboutInformation.build(from: infoDictionary)
                )
            } header: {
                Text("Flux News")
            } footer: {
                Text("© 2023 Kevin Fechtel")
            }

            Section {
                Link(destination: IOSAboutInformation.fluxNewsRepositoryURL) {
                    Label(
                        "FluxNews Repository",
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
                Link(destination: IOSAboutInformation.fluxRepositoryURL) {
                    Label(
                        "Flux Development Repository",
                        systemImage: "shippingbox"
                    )
                }
                Link(destination: IOSAboutInformation.licenseURL) {
                    Label("BSD 3-Clause License", systemImage: "doc.text")
                }
            } header: {
                Text("Open Source")
            } footer: {
                Text(
                    "Flux News is open source. The application project is moving to the FluxNews repository; the Flux repository remains available for the current native development history and shared Core."
                )
            }

            Section {
                Text(
                    "Flux News is a newsreader and podcast client for the Miniflux backend."
                )
                Link(destination: IOSAboutInformation.minifluxProjectURL) {
                    Label("Miniflux Project", systemImage: "safari")
                }
            } header: {
                Text("Miniflux")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
