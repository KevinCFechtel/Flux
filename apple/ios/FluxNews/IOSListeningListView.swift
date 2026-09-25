import SwiftUI

struct IOSListeningListView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: IOSListeningListStore
    @ObservedObject var playbackState: IOSMediaPlaybackPresentationState
    @ObservedObject var transferState: IOSMediaTransferPresentationState
    let playbackCoordinator: IOSMediaPlaybackCoordinator
    let showsScopeChooser: Bool
    let onPresentScopeChooser: () -> Void
    let onOpenPlayer: (_ articleID: Int64) -> Void
    let onPlay: (_ articleID: Int64, _ enclosureID: Int64) -> Void
    let feedIconState: (_ feedID: Int64, _ variant: FeedIconVariant) -> IOSFeedIconPresentationState
    let onRequestFeedIcon: (_ feedID: Int64, _ variant: FeedIconVariant) -> Void

    private static let isoFormatter = ISO8601DateFormatter()

    var body: some View {
        Group {
            if store.isLoading && store.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.errorMessage, store.items.isEmpty {
                ContentUnavailableView {
                    Label("Listening List", systemImage: "headphones")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { store.reload() }
                }
            } else if store.items.isEmpty {
                ContentUnavailableView(
                    "Listening List is Empty",
                    systemImage: "headphones",
                    description: Text(
                        "Add audio news to your Listening List to find them here."
                    )
                )
            } else {
                List(store.items, id: \.articleId) { item in
                    row(item)
                }
                .refreshable { store.reload() }
            }
        }
        .navigationTitle("Listening List")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if showsScopeChooser {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onPresentScopeChooser) {
                        Image(IOSNavigationButtonPresentation.imageName)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(
                                width: IOSNavigationButtonPresentation.glyphSize,
                                height: IOSNavigationButtonPresentation.glyphSize
                            )
                    }
                    .accessibilityLabel(
                        IOSNavigationButtonPresentation.accessibilityLabel
                    )
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                feedMenu
                sortMenu
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ListeningListItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        IOSListeningListPresentation.textOrFallback(
                            item.title,
                            fallback: String(localized: "Untitled News")
                        )
                    )
                    .font(.headline)
                    .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        FeedIconView(
                            feedID: item.feedId,
                            title: item.feedTitle,
                            state: feedIconState(
                                item.feedId,
                                feedIconVariant
                            ),
                            onRequest: {
                                onRequestFeedIcon(
                                    item.feedId,
                                    feedIconVariant
                                )
                            },
                            size: 16
                        )
                        Text(
                            IOSListeningListPresentation.textOrFallback(
                                item.feedTitle,
                                fallback: String(localized: "Unknown Feed")
                            )
                        )
                        if let date = Self.isoFormatter.date(
                            from: item.publishedAt
                        ) {
                            Text("·")
                            Text(
                                date.formatted(
                                    date: .abbreviated,
                                    time: .omitted
                                )
                            )
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenPlayer(item.articleId)
                }

                Spacer(minLength: 8)
                itemMenu(item)
            }

            if let progress = IOSListeningListPresentation.progress(
                item,
                runtime: playbackState
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                    }
                    Text(progressLabel(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenPlayer(item.articleId)
                }
            }

            let downloads = IOSListeningListPresentation.downloadSummary(
                item,
                transfers: transferState.transfers
            )
            HStack(spacing: 10) {
                HStack(spacing: 12) {
                    mediaStatusMetric(
                        enclosureLabel(item.audioEnclosures.count),
                        systemImage: "waveform"
                    )
                    if downloads.downloaded > 0 {
                        mediaStatusMetric(
                            String(localized: "\(downloads.downloaded) downloaded"),
                            systemImage: "arrow.down.circle.fill"
                        )
                    } else if downloads.pending > 0 {
                        mediaStatusMetric(
                            String(localized: "\(downloads.pending) pending"),
                            systemImage: "clock"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenPlayer(item.articleId)
                }

                primaryPlayControl(item)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let transfer = IOSListeningListPresentation.transferProgress(
                item,
                transfers: transferState.transfers
            ) {
                HStack(spacing: 8) {
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text(transfer.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenPlayer(item.articleId)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func primaryPlayControl(_ item: ListeningListItem) -> some View {
        if let enclosure = IOSListeningListPresentation.selectedEnclosure(item) {
            let action = IOSListeningListPresentation.playbackAction(
                enclosureID: enclosure.enclosure.id,
                loadedEnclosureID: playbackState.loadedEnclosure?.id,
                status: playbackState.status
            )
            Button {
                performPlaybackAction(
                    action,
                    item: item,
                    enclosureID: enclosure.enclosure.id
                )
            } label: {
                Label(
                    action == .pause
                        ? String(localized: "Pause")
                        : String(localized: "Play"),
                    systemImage: action == .pause
                        ? "pause.fill"
                        : "play.fill"
                )
            }
            .buttonStyle(.bordered)
        } else if !item.audioEnclosures.isEmpty {
            Menu {
                ForEach(
                    Array(item.audioEnclosures.enumerated()),
                    id: \.element.enclosure.id
                ) { index, enclosure in
                    Button {
                        onPlay(
                            item.articleId,
                            enclosure.enclosure.id
                        )
                    } label: {
                        Text(
                            IOSListeningListPresentation.enclosureLabel(
                                enclosure.enclosure,
                                index: index
                            )
                        )
                    }
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
        }
    }

    private func itemMenu(_ item: ListeningListItem) -> some View {
        Menu {
            ForEach(
                Array(item.audioEnclosures.enumerated()),
                id: \.element.enclosure.id
            ) { index, enclosure in
                Menu {
                    let action = IOSListeningListPresentation.playbackAction(
                        enclosureID: enclosure.enclosure.id,
                        loadedEnclosureID: playbackState.loadedEnclosure?.id,
                        status: playbackState.status
                    )
                    Button {
                        performPlaybackAction(
                            action,
                            item: item,
                            enclosureID: enclosure.enclosure.id
                        )
                    } label: {
                        Label(
                            action == .pause
                                ? String(localized: "Pause")
                                : String(localized: "Play"),
                            systemImage: action == .pause
                                ? "pause.fill"
                                : "play.fill"
                        )
                    }

                    downloadAction(
                        enclosure,
                        label: IOSListeningListPresentation.enclosureLabel(
                            enclosure.enclosure,
                            index: index
                        )
                    )
                } label: {
                    Label(
                        IOSListeningListPresentation.enclosureLabel(
                            enclosure.enclosure,
                            index: index
                        ),
                        systemImage: "waveform"
                    )
                }
            }

            Divider()

            Button(role: .destructive) {
                Task {
                    await store.removeFromListeningList(
                        articleID: item.articleId
                    )
                }
            } label: {
                Label(
                    "Remove from Listening List",
                    systemImage: "minus.circle"
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Listening List actions"))
    }

    private func performPlaybackAction(
        _ action: IOSListeningListPresentation.PlaybackAction,
        item: ListeningListItem,
        enclosureID: Int64
    ) {
        switch action {
        case .pause:
            playbackCoordinator.pause()
        case .play:
            onPlay(item.articleId, enclosureID)
        }
    }

    @ViewBuilder
    private func downloadAction(
        _ enclosure: ListeningListEnclosure,
        label: String
    ) -> some View {
        let action = IOSListeningListPresentation.downloadAction(
            enclosure,
            runtime: transferState.runtime(for: enclosure.enclosure.id)
        )
        switch action {
        case .delete:
            Button(role: .destructive) {
                Task {
                    await store.deleteDownload(
                        enclosureID: enclosure.enclosure.id
                    )
                }
            } label: {
                Label("Delete Download", systemImage: "trash")
            }

        case .pending, .downloading:
            Button {
                Task {
                    await store.cancelDownload(
                        enclosureID: enclosure.enclosure.id
                    )
                }
            } label: {
                if action == .downloading,
                   let fraction = transferState.runtime(
                       for: enclosure.enclosure.id
                   )?.fraction {
                    Label(
                        String(
                            localized: "\(Int((fraction * 100).rounded()))% downloaded"
                        ),
                        systemImage: "xmark.circle"
                    )
                } else {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            }

        case .cancelling:
            Label("Cancelling Download", systemImage: "clock")

        case .retry:
            Button {
                Task {
                    await store.retryDownload(
                        enclosureID: enclosure.enclosure.id
                    )
                }
            } label: {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }

        case .pendingDeletion:
            Label("Deletion Pending", systemImage: "clock")

        case .download:
            Button {
                Task {
                    await store.requestDownload(
                        enclosureID: enclosure.enclosure.id
                    )
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
    }

    private var feedMenu: some View {
        Menu {
            Button {
                store.setFeedID(nil)
            } label: {
                filterLabel(
                    String(localized: "All Feeds"),
                    selected: store.feedID == nil
                )
            }

            ForEach(store.feeds, id: \.feedId) { feed in
                Button {
                    store.setFeedID(feed.feedId)
                } label: {
                    filterLabel(
                        feed.feedTitle,
                        selected: store.feedID == feed.feedId
                    )
                }
            }
        } label: {
            Label("Feed", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(String(localized: "Filter Listening List by feed"))
    }

    private var sortMenu: some View {
        Menu {
            Button {
                store.setSort(.recentlyAdded)
            } label: {
                filterLabel(
                    String(localized: "Recently Added"),
                    selected: store.sort == .recentlyAdded
                )
            }
            Button {
                store.setSort(.publicationDate)
            } label: {
                filterLabel(
                    String(localized: "Publication Date"),
                    selected: store.sort == .publicationDate
                )
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel(String(localized: "Sort Listening List"))
    }

    @ViewBuilder
    private func filterLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func progressLabel(
        _ progress: IOSListeningListPresentation.Progress
    ) -> String {
        let position = Duration.seconds(Double(progress.positionMs) / 1_000)
            .formatted(.time(pattern: .minuteSecond))
        guard let duration = progress.durationMs else {
            return position
        }
        let total = Duration.seconds(Double(duration) / 1_000)
            .formatted(.time(pattern: .minuteSecond))
        return "\(position) / \(total)"
    }

    private var feedIconVariant: FeedIconVariant {
        IOSFeedIconPresentation.variant(
            isDark: colorScheme == .dark
        )
    }

    private func mediaStatusMetric(
        _ text: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func enclosureLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 audio")
            : String(localized: "\(count) audio")
    }
}
