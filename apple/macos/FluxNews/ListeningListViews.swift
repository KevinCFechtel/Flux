import SwiftUI

struct ListeningListView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var playbackState: MediaPlaybackPresentationState
    @ObservedObject var transferState: MediaTransferPresentationState
    let onPlay: (Enclosure) -> Void
    let onDownload: (Int64, Int64) -> Void
    let onDelete: (Int64, Int64) -> Void
    let onCancel: (Int64, Int64) -> Void
    let onRemove: (Int64) -> Void

    var body: some View {
        if let error = store.errorMessage, store.listeningListItems.isEmpty {
            ContentUnavailableView("Listening List unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.listeningListItems.isEmpty {
            ContentUnavailableView("Listening List is Empty", systemImage: "headphones", description: Text("Audio News added to the Listening List will appear here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.listeningListItems, id: \.articleId) { item in
                        ListeningListRow(item: item, store: store, playbackState: playbackState, transferState: transferState, onPlay: onPlay, onDownload: onDownload, onDelete: onDelete, onCancel: onCancel, onRemove: onRemove)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }
}

private struct ListeningListRow: View {
    let item: ListeningListItem
    @ObservedObject var store: BrowserStore
    @ObservedObject var playbackState: MediaPlaybackPresentationState
    @ObservedObject var transferState: MediaTransferPresentationState
    let onPlay: (Enclosure) -> Void
    let onDownload: (Int64, Int64) -> Void
    let onDelete: (Int64, Int64) -> Void
    let onCancel: (Int64, Int64) -> Void
    let onRemove: (Int64) -> Void
    @State private var confirmingRemoval = false
    @State private var pendingDeletion: ListeningListEnclosure?
    private static let isoFormatter = ISO8601DateFormatter()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ListeningListPresentation.textOrFallback(item.title, fallback: String(localized: "Untitled News")))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(3)
                HStack(spacing: 5) {
                    FeedIconSlot(feedID: item.feedId, store: store)
                    Text(ListeningListPresentation.textOrFallback(item.feedTitle, fallback: String(localized: "Unknown Feed"))).foregroundStyle(.secondary)
                    if let date = Self.isoFormatter.date(from: item.publishedAt) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                progress
            }
            Spacer(minLength: 4)
            status
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { if let enclosure = ListeningListPresentation.preferredEnclosure(item) { onPlay(enclosure) } }
        .contextMenuIf(item.audioEnclosures.count > 1 && item.activeEnclosureId == nil) {
            ForEach(item.audioEnclosures, id: \.enclosure.id) { audio in
                Button("Play \(ArticleAudioActions.enclosureLabel(audio.enclosure, index: item.audioEnclosures.firstIndex(where: { $0.enclosure.id == audio.enclosure.id }) ?? 0))") { onPlay(audio.enclosure) }
            }
        }
        .alert("Remove from Listening List?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) { confirmingRemoval = false }
            Button("Remove", role: .destructive) { confirmingRemoval = false; onRemove(item.articleId) }
        } message: {
            Text("Downloaded audio for this item will also be deleted.")
        }
        .alert("Delete Download?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let audio = pendingDeletion { pendingDeletion = nil; onDelete(item.articleId, audio.enclosure.id) }
            }
        } message: {
            Text("The downloaded audio file will be deleted.")
        }
    }

    @ViewBuilder private var progress: some View {
        if let value = ListeningListPresentation.progress(item, runtime: playbackState) {
            if value.status == .completed {
                ProgressView(value: 1)
                    .progressViewStyle(.linear)
                    .tint(.green)
                Text("Completed").foregroundStyle(.secondary)
            } else if let duration = value.durationMs, duration > 0 {
                ProgressView(value: min(Double(value.positionMs) / Double(duration), 1))
                    .progressViewStyle(.linear)
                Text("\(Self.minutes(value.positionMs)) / \(Self.minutes(duration)) min").foregroundStyle(.secondary)
            } else if value.positionMs > 0 {
                Text("\(Self.minutes(value.positionMs)) min").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if ListeningListPresentation.preferredEnclosure(item) == nil {
                Menu {
                    ForEach(item.audioEnclosures.indices, id: \.self) { index in
                        let audio = item.audioEnclosures[index]
                        Button(ArticleAudioActions.enclosureLabel(audio.enclosure, index: index)) { onPlay(audio.enclosure) }
                    }
                } label: {
                    Image(systemName: "play.fill")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Choose audio to play")
            }
            let count = ListeningListPresentation.downloadedCount(item)
            HStack(spacing: 4) {
                DownloadControl(item: item, transferState: transferState, onDownload: onDownload, onDelete: { pendingDeletion = $0 }, onCancel: onCancel)
                if count.total > 1 {
                    Text("\(count.downloaded)/\(count.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                if ArticleAudioActions.hasLocalDownload(item) { confirmingRemoval = true }
                else { onRemove(item.articleId) }
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove from Listening List")
                .accessibilityLabel("Remove from Listening List")
        }
    }

    private static func minutes(_ milliseconds: UInt64) -> String {
        String(max(0, Int(milliseconds / 60_000)))
    }

}

private struct DownloadControl: View {
    let item: ListeningListItem
    @ObservedObject var transferState: MediaTransferPresentationState
    let onDownload: (Int64, Int64) -> Void
    let onDelete: (ListeningListEnclosure) -> Void
    let onCancel: (Int64, Int64) -> Void
    @State private var hoveredDownloadedID: Int64?

    var body: some View {
        if item.audioEnclosures.isEmpty {
            EmptyView()
        } else if item.audioEnclosures.count == 1, let audio = item.audioEnclosures.first {
            control(for: audio)
        } else {
            Menu {
                ForEach(item.audioEnclosures.indices, id: \.self) { index in
                    let audio = item.audioEnclosures[index]
                    Button {
                        activate(audio)
                    } label: {
                        Label(actionTitle(audio, index: index), systemImage: symbol(for: audio))
                    }
                    .disabled(!isActionable(audio))
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Download")
            .accessibilityLabel("Download")
        }
    }

    @ViewBuilder private func control(for audio: ListeningListEnclosure) -> some View {
        let action = ArticleAudioActions.downloadAction(audio.download, runtime: transferState.runtime(for: audio.enclosure.id))
        switch action {
        case .downloading:
            HStack(spacing: 4) {
                ProgressView(value: transferState.runtime(for: audio.enclosure.id)?.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Button { onCancel(item.articleId, audio.enclosure.id) } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Cancel Download")
                .accessibilityLabel("Cancel Download")
            }
        case .pending:
            Button { onCancel(item.articleId, audio.enclosure.id) } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
        case .pendingDeletion:
            ProgressView().controlSize(.small).help("Delete Download pending")
        default:
            Button { activate(audio) } label: {
                Image(systemName: symbol(for: audio))
                    .foregroundStyle(action == .delete ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!isActionable(audio))
            .onHover { isHovered in
                hoveredDownloadedID = isHovered && action == .delete ? audio.enclosure.id : nil
            }
            .help(action == .delete && hoveredDownloadedID == audio.enclosure.id ? "Delete Download" : action == .retry ? "Retry Download" : "Download")
            .accessibilityLabel(action == .delete ? "Downloaded" : action == .retry ? "Retry Download" : "Download")
        }
    }

    private func activate(_ audio: ListeningListEnclosure) {
        let action = ArticleAudioActions.downloadAction(audio.download, runtime: transferState.runtime(for: audio.enclosure.id))
        if action == .downloading || action == .pending { onCancel(item.articleId, audio.enclosure.id); return }
        if ArticleAudioActions.canDeleteDownload(audio.download) { onDelete(audio) }
        else if ArticleAudioActions.canRequestDownload(audio.download) { onDownload(item.articleId, audio.enclosure.id) }
    }

    private func isActionable(_ audio: ListeningListEnclosure) -> Bool {
        let action = ArticleAudioActions.downloadAction(audio.download, runtime: transferState.runtime(for: audio.enclosure.id))
        return action == .downloading || action == .pending || ArticleAudioActions.canRequestDownload(audio.download) || ArticleAudioActions.canDeleteDownload(audio.download)
    }

    private func symbol(for audio: ListeningListEnclosure) -> String {
        let action = ArticleAudioActions.downloadAction(audio.download, runtime: transferState.runtime(for: audio.enclosure.id))
        if action == .delete && hoveredDownloadedID == audio.enclosure.id { return "trash" }
        switch action {
        case .delete: return "checkmark.circle.fill"
        case .downloading, .pending: return "xmark.circle"
        case .retry: return "arrow.clockwise.circle"
        default: return "arrow.down.circle"
        }
    }

    private func actionTitle(_ audio: ListeningListEnclosure, index: Int) -> String {
        let label = ArticleAudioActions.enclosureLabel(audio.enclosure, index: index)
        switch ArticleAudioActions.downloadAction(audio.download, runtime: transferState.runtime(for: audio.enclosure.id)) {
        case .delete: return String(localized: "Delete Download: \(label)")
        case .pending: return String(localized: "Cancel Download: \(label)")
        case .downloading: return String(localized: "Cancel Download: \(label)")
        case .pendingDeletion: return String(localized: "Delete Download pending: \(label)")
        case .retry: return String(localized: "Retry Download: \(label)")
        case .download: return String(localized: "Download: \(label)")
        }
    }
}

private extension View {
    @ViewBuilder
    func contextMenuIf<Content: View>(_ enabled: Bool, @ViewBuilder content: @escaping () -> Content) -> some View {
        if enabled {
            contextMenu { content() }
        } else {
            self
        }
    }
}
