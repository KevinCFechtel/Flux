import SwiftUI

struct IOSListeningListView: View {
    @ObservedObject var store: IOSListeningListStore
    @ObservedObject var playbackState: IOSMediaPlaybackPresentationState
    let playbackCoordinator: IOSMediaPlaybackCoordinator

    @State private var playerPresented = false
    @State private var playerArticleID: Int64?

    private static let isoFormatter = ISO8601DateFormatter()

    var body: some View {
        NavigationStack {
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
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    feedMenu
                    sortMenu
                }
            }
            .sheet(isPresented: $playerPresented, onDismiss: {
                store.clearShowNotes()
            }) {
                IOSMediaPlayerView(
                    playbackState: playbackState,
                    playbackCoordinator: playbackCoordinator,
                    item: playerItem,
                    showNotesDocument: store.showNotesDocument,
                    showNotesIsLoading: store.showNotesIsLoading,
                    showNotesErrorMessage: store.showNotesErrorMessage,
                    onSelectEnclosure: { enclosureID in
                        startPlayback(
                            articleID: playerArticleID,
                            enclosureID: enclosureID
                        )
                    },
                    onShowNotes: {
                        if let playerArticleID {
                            store.loadShowNotes(articleID: playerArticleID)
                        }
                    },
                    onDismiss: {
                        playerPresented = false
                    }
                )
            }
        }
    }

    private var playerItem: ListeningListItem? {
        guard let playerArticleID else { return nil }
        return store.items.first { $0.articleId == playerArticleID }
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
            }

            let downloads = IOSListeningListPresentation.downloadSummary(item)
            HStack(spacing: 12) {
                Label(
                    enclosureLabel(item.audioEnclosures.count),
                    systemImage: "waveform"
                )
                if downloads.downloaded > 0 {
                    Label(
                        String(localized: "\(downloads.downloaded) downloaded"),
                        systemImage: "arrow.down.circle.fill"
                    )
                } else if downloads.pending > 0 {
                    Label(
                        String(localized: "\(downloads.pending) pending"),
                        systemImage: "clock"
                    )
                }
                Spacer()
                primaryPlayControl(item)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func primaryPlayControl(_ item: ListeningListItem) -> some View {
        if let enclosure = IOSListeningListPresentation.selectedEnclosure(item) {
            let isCurrent = playbackState.loadedEnclosure?.id
                == enclosure.enclosure.id
            Button {
                if isCurrent && playbackState.status == .playing {
                    playbackCoordinator.pause()
                } else {
                    startPlayback(
                        articleID: item.articleId,
                        enclosureID: enclosure.enclosure.id
                    )
                }
            } label: {
                Label(
                    isCurrent && playbackState.status == .playing
                        ? String(localized: "Pause")
                        : String(localized: "Play"),
                    systemImage: isCurrent && playbackState.status == .playing
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
                        startPlayback(
                            articleID: item.articleId,
                            enclosureID: enclosure.enclosure.id
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
                    Button {
                        startPlayback(
                            articleID: item.articleId,
                            enclosureID: enclosure.enclosure.id
                        )
                    } label: {
                        Label("Play", systemImage: "play.fill")
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
        }
        .accessibilityLabel(String(localized: "Listening List actions"))
    }

    @ViewBuilder
    private func downloadAction(
        _ enclosure: ListeningListEnclosure,
        label: String
    ) -> some View {
        switch enclosure.download?.state {
        case .downloaded:
            Button(role: .destructive) {
                Task {
                    await store.deleteDownload(
                        enclosureID: enclosure.enclosure.id
                    )
                }
            } label: {
                Label("Delete Download", systemImage: "trash")
            }

        case .requested:
            Button {
                Task {
                    await store.cancelDownload(
                        enclosureID: enclosure.enclosure.id
                    )
                }
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }

        case .failed:
            Button {
                Task {
                    await store.retryDownload(
                        enclosureID: enclosure.enclosure.id
                    )
                }
            } label: {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }

        case .deleteRequested:
            Label("Deletion Pending", systemImage: "clock")

        case .notDownloaded, nil:
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

    private func startPlayback(
        articleID: Int64?,
        enclosureID: Int64
    ) {
        if let articleID {
            playerArticleID = articleID
        }
        playerPresented = true
        Task {
            do {
                try await playbackCoordinator.play(
                    enclosureID: enclosureID
                )
                store.reload()
            } catch {
                playbackState.setErrorMessage(
                    playbackCoordinator.lastStartFailureDescription
                        ?? error.localizedDescription
                )
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

    private func enclosureLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 audio")
            : String(localized: "\(count) audio")
    }
}
