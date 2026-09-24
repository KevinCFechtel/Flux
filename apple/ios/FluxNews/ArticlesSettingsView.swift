import SwiftUI

struct ArticlesSettingsView: View {
    var store: NewsreaderStore
    @ObservedObject var bootstrapper: CoreBootstrapper

    @State private var liveMutationDeliveryEnabled = true
    @State private var mutationDeliveryLoaded = false
    @State private var mutationDeliverySaving = false
    @State private var mutationDeliveryError: String?

    var body: some View {
        Form {
            Picker("Open article", selection: Binding(get: { store.clickOnNews }, set: store.setClickOnNews)) {
                Text("Original link").tag(ClickOnNews.openLink)
                Text("Reader").tag(ClickOnNews.openDetailView)
            }
            Picker("Presentation", selection: Binding(get: { store.articlePresentationMode }, set: store.setArticlePresentationMode)) {
                ForEach(ArticlePresentationMode.allCases, id: \.self) { Text(String(localized: String.LocalizationValue($0.displayNameKey))).tag($0) }
            }
            Picker("Preview lines", selection: Binding(get: { store.articlePreviewLines }, set: store.setArticlePreviewLines)) {
                ForEach(ArticlePreviewLines.allCases, id: \.self) { Text(String(format: String(localized: "%lld lines"), $0.rawValue)).tag($0) }
            }
            Toggle("Show article count", isOn: Binding(get: { store.showArticleCount }, set: store.setShowArticleCount))
            Toggle("Show relative publication time", isOn: Binding(get: { store.showRelativePublicationTime }, set: store.setShowRelativePublicationTime))
            Toggle("Remove articles when read", isOn: Binding(get: { store.removeArticlesWhenMarkedRead }, set: store.setRemoveArticlesWhenMarkedRead))
            Toggle("Mark read on scrollover", isOn: Binding(get: { store.markReadOnScrolloverEnabled }, set: store.setMarkReadOnScrolloverEnabled))

            Section {
                Toggle(
                    "Sync article changes immediately",
                    isOn: Binding(
                        get: { liveMutationDeliveryEnabled },
                        set: { newValue in
                            guard mutationDeliveryLoaded, !mutationDeliverySaving else { return }
                            let previous = liveMutationDeliveryEnabled
                            liveMutationDeliveryEnabled = newValue
                            mutationDeliverySaving = true
                            mutationDeliveryError = nil
                            Task {
                                let result = await bootstrapper.setMutationDeliveryPreference(newValue)
                                switch result {
                                case .success:
                                    break
                                case .failure:
                                    liveMutationDeliveryEnabled = previous
                                    mutationDeliveryError = String(
                                        localized: "Immediate article sync setting could not be saved. Please try again."
                                    )
                                }
                                mutationDeliverySaving = false
                            }
                        }
                    )
                )
                .disabled(!mutationDeliveryLoaded || mutationDeliverySaving)
            } footer: {
                Text("When enabled, read/unread and star changes are saved locally first and then sent to Miniflux immediately. If delivery fails, FluxNews keeps the change pending for a later retry.")
            }

            if mutationDeliverySaving {
                Section {
                    HStack {
                        ProgressView()
                        Text("Saving…")
                    }
                }
            }

            if let mutationDeliveryError {
                Section {
                    Text(mutationDeliveryError)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Articles")
        .task {
            guard !mutationDeliveryLoaded else { return }
            let result = await bootstrapper.mutationDeliveryPreference()
            switch result {
            case let .success(enabled):
                liveMutationDeliveryEnabled = enabled
                mutationDeliveryLoaded = true
            case .failure:
                mutationDeliveryError = String(
                    localized: "Immediate article sync setting could not be loaded. Please try again."
                )
            }
        }
    }
}
