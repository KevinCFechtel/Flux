import SwiftUI

struct IOSListeningListView: View {
    @ObservedObject var store: IOSListeningListStore
    @ObservedObject var playbackState: IOSMediaPlaybackPresentationState

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
        }
    }

    @ViewBuilder
    private func row(_ item: ListeningListItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                if let date = Self.isoFormatter.date(from: item.publishedAt) {
                    Text("·")
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

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
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
