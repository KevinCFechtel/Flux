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

            Section("Swipe Actions") {
                swipeSideSettings(
                    title: String(localized: "Leading Side"),
                    side: .leading
                )
                swipeSideSettings(
                    title: String(localized: "Trailing Side"),
                    side: .trailing
                )
            } footer: {
                Text("Each side supports up to two actions. The Full Swipe action is the outer action and runs when you deliberately swipe through the row.")
            }

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

    @ViewBuilder
    private func swipeSideSettings(
        title: String,
        side: IOSArticleSwipeSide
    ) -> some View {
        let configuration = store.articleSwipeConfiguration
        let fullSwipe = configuration.fullSwipeAction(for: side)
        let additional = configuration.additionalAction(for: side)

        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Picker(
                "Full Swipe",
                selection: Binding<IOSArticleSwipeAction?>(
                    get: {
                        store.articleSwipeConfiguration.fullSwipeAction(for: side)
                    },
                    set: { store.setArticleSwipeAction($0, side: side, slot: .fullSwipe) }
                )
            ) {
                Text("None").tag(IOSArticleSwipeAction?.none)
                ForEach(IOSArticleSwipeAction.allCases, id: \.self) { action in
                    Text(action.title).tag(Optional(action))
                }
            }

            Picker(
                "Additional Action",
                selection: Binding<IOSArticleSwipeAction?>(
                    get: {
                        store.articleSwipeConfiguration.additionalAction(for: side)
                    },
                    set: { store.setArticleSwipeAction($0, side: side, slot: .additional) }
                )
            ) {
                Text("None").tag(IOSArticleSwipeAction?.none)
                ForEach(IOSArticleSwipeAction.allCases, id: \.self) { action in
                    Text(action.title).tag(Optional(action))
                }
            }
            .disabled(fullSwipe == nil)

            if let fullSwipe {
                Text(
                    additional == nil
                        ? String(
                            format: String(localized: "Full Swipe: %@"),
                            fullSwipe.title
                        )
                        : String(
                            format: String(localized: "Inner: %@ · Full Swipe: %@"),
                            additional?.title ?? "",
                            fullSwipe.title
                        )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
