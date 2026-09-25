import SwiftUI
import UIKit
import SafariServices

private struct IOSBrowserURL: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct IOSReaderArticle: Identifiable {
    let article: ArticleSummary
    var id: Int64 { article.id }
}

private struct IOSSharePayload: Identifiable {
    let items: [Any]
    let id = UUID()
}

enum IOSBottomAction: Equatable {
    case sync
    case filterAndSort
    case search
    case listeningList
    case markAllRead
    case markAllReadAndNext
    case settings
    case more

    static let defaultActions: [Self] = [.sync, .filterAndSort, .more]
}

enum IOSArticleListActionPlacement: Equatable {
    case bottomBar
    case topBarTrailing
    case floatingTopTrailing
}

enum IOSArticleListChromeMode: Equatable {
    case compactPortrait
    case compactLandscape
    case persistentSplit
    case persistentSplitCollapsed
}

enum IOSArticleListTitleCapsulePlacement: Equatable {
    case floatingTopCenter
    case navigationTopLeading
    case floatingTopLeading
    case hidden
}

enum IOSArticleListChromePresentation {
    static func mode(
        for presentation: AdaptivePresentation,
        verticalSizeClass: UserInterfaceSizeClass?,
        splitColumnVisibility: NavigationSplitViewVisibility
    ) -> IOSArticleListChromeMode {
        // Actual visible split chrome wins over the nominal size-class mode. This
        // prevents duplicate scope UI during a transient/system-driven split
        // transition: if a sidebar is visible, the title capsule must disappear.
        if splitColumnVisibility != .detailOnly {
            return .persistentSplit
        }
        if presentation.usesPersistentSplitNavigation {
            return .persistentSplitCollapsed
        }
        return verticalSizeClass == .compact ? .compactLandscape : .compactPortrait
    }

    static func actionPlacement(
        for mode: IOSArticleListChromeMode,
        systemPrefersVerticalToolbar: Bool = false
    ) -> IOSArticleListActionPlacement {
        switch mode {
        case .compactPortrait:
            .bottomBar
        case .compactLandscape:
            .topBarTrailing
        case .persistentSplit, .persistentSplitCollapsed:
            systemPrefersVerticalToolbar ? .topBarTrailing : .floatingTopTrailing
        }
    }

    static func titleCapsulePlacement(for mode: IOSArticleListChromeMode) -> IOSArticleListTitleCapsulePlacement {
        switch mode {
        case .compactPortrait:
            .floatingTopCenter
        case .compactLandscape:
            .navigationTopLeading
        case .persistentSplitCollapsed:
            .floatingTopLeading
        case .persistentSplit:
            .hidden
        }
    }

    static func showsTopNavigationBar(
        for mode: IOSArticleListChromeMode,
        systemPrefersVerticalToolbar: Bool = false
    ) -> Bool {
        if mode == .compactLandscape { return true }
        return systemPrefersVerticalToolbar && {
            switch mode {
            case .persistentSplit, .persistentSplitCollapsed:
                true
            case .compactPortrait, .compactLandscape:
                false
            }
        }()
    }

    static func usesNativeTopEdgeEffect(
        for mode: IOSArticleListChromeMode,
        systemPrefersVerticalToolbar: Bool = false
    ) -> Bool {
        // Vertical-bar preference changes where actions live, not the Timeline's
        // established top-edge policy. Only compact iPhone landscape disables it.
        _ = systemPrefersVerticalToolbar
        return mode != .compactLandscape
    }
}

enum IOSListeningListNavigationPresentation {
    static func showsScopeChooser(
        for presentation: AdaptivePresentation,
        splitColumnVisibility: NavigationSplitViewVisibility
    ) -> Bool {
        !presentation.usesPersistentSplitNavigation
            || splitColumnVisibility == .detailOnly
    }
}

enum IOSArticleListActionChromeMetrics {
    static let floatingHorizontalPadding: CGFloat = 8
    static let floatingVerticalPadding: CGFloat = 5
    static let floatingSpacing: CGFloat = 6
}

enum IOSArticleListTitleCapsuleMetrics {
    /// The title capsule is deliberately outside UINavigationBar chrome. These
    /// insets create a small transparent floating row without registering the
    /// capsule as a scroll-edge element.
    static let floatingHorizontalInset: CGFloat = 12
    static let floatingVerticalInset: CGFloat = 4
    static let floatingRowSpacing: CGFloat = 10
    static let stackedVerticalPadding: CGFloat = 7

    static func portraitNaturalTopContentInset(showSubtitle: Bool) -> CGFloat {
        let titleHeight = UIFont.preferredFont(forTextStyle: .headline).lineHeight
        let contentHeight = showSubtitle
            ? titleHeight + 1 + UIFont.preferredFont(forTextStyle: .caption1).lineHeight
            : titleHeight
        return contentHeight
            + (stackedVerticalPadding * 2)
            + (floatingVerticalInset * 2)
    }

    /// The iPad collapsed-split inline capsule still needs a useful minimum title
    /// width beside the trailing toolbar actions.
    static let inlineMinimumContentWidth: CGFloat = 280
    /// Count semantics are more important than preserving every character of a
    /// long scope/feed title in the remaining inline iPad presentation.
    static let inlineTitlePriority: Double = 1
    static let inlineCountPriority: Double = 2

    /// Compact-height iPhone landscape uses the same two-line information
    /// hierarchy as portrait, but trims the capsule itself so the separate
    /// floating row does not consume unnecessary landscape height.
    static let compactStackedVerticalPadding: CGFloat = 0
    static let compactStackedHorizontalPadding: CGFloat = 8
    static let compactStackedSpacing: CGFloat = 6
    /// Give ordinary feed/category titles enough room in the independent floating
    /// row. Very long titles may still truncate rather than claiming the full
    /// detail width.
    static let compactStackedMinimumContentWidth: CGFloat = 190
    static let compactStackedTitlePriority: Double = 3
}

enum IOSMoreAction: Equatable {
    case markAllRead
    case markAllReadAndNext
    case settings

    static func actions(for scope: BrowserScope, hasNextScope: Bool) -> [Self] {
        let supportsMarkRead: Bool = switch scope {
        case .all, .category, .feed: true
        case .starred, .search, .listeningList: false
        }
        guard supportsMarkRead else { return [.settings] }
        let canAdvance = hasNextScope && {
            switch scope {
            case .category, .feed: true
            case .all, .starred, .search, .listeningList: false
            }
        }()
        return canAdvance ? [.markAllRead, .markAllReadAndNext, .settings] : [.markAllRead, .settings]
    }
}

enum IOSScopeNavigation {
    static func nextScope(
        after scope: BrowserScope,
        catalog: NavigationCatalog,
        hidingEmpty: Bool,
        counts: [Int64: UInt64]
    ) -> BrowserScope? {
        let groups = NavigationVisibility.groups(
            categories: catalog.categories.map { .init(id: $0.id, title: $0.title) },
            feeds: catalog.feeds.map { .init(id: $0.id, categoryID: $0.categoryId) },
            hidingEmpty: hidingEmpty,
            counts: counts
        )
        switch scope {
        case let .feed(feedID):
            let feeds = groups.flatMap(\.feeds)
            guard let index = feeds.firstIndex(where: { $0.id == feedID }), feeds.indices.contains(feeds.index(after: index)) else { return nil }
            return .feed(feeds[feeds.index(after: index)].id)
        case let .category(categoryID):
            let categories = groups.compactMap(\.categoryID)
            guard let index = categories.firstIndex(of: categoryID), categories.indices.contains(categories.index(after: index)) else { return nil }
            return .category(categories[categories.index(after: index)])
        case .all, .starred, .search, .listeningList:
            return nil
        }
    }
}

private enum IOSMarkReadWorkflow: Equatable {
    case read
    case readAndNext
}

enum IOSNavigationButtonPresentation {
    static let imageName = "FluxNewsTemplate"
    static let accessibilityLabel = String(localized: "Choose news scope")
    static let glyphSize: CGFloat = 22
}

enum IOSReaderDismissalPresentation {
    static let title = String(localized: "Done")
}

enum IOSArticleNavigationPresentation {
    // Keep the outer navigation container on the native large-title-compatible
    // path so semantic resets preserve the expected navigation-controller
    // geometry. The accepted visible article-list title remains the explicit
    // scope capsule, whose inner chrome overrides the visible display mode.
    static let titleDisplayMode: NavigationBarItem.TitleDisplayMode = .large
}

#if FLUX_HAS_VERTICAL_TOOLBAR_API
@available(iOS 27.1, *)
private struct IOSArticleListVerticalToolbarEnvironment<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge
    private let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(toolbarVerticalEdge != nil)
    }
}
#endif

private struct IOSArticleMediaPlayerPresentation: Identifiable {
    let article: ArticleSummary
    let enclosureID: Int64
    var id: String { "\(article.id):\(enclosureID)" }
}

private enum IOSArticleMediaSource {
    case news
    case search
}

private struct IOSArticleMediaDownloadChoice: Identifiable {
    let article: ArticleSummary
    let enclosures: [Enclosure]
    let source: IOSArticleMediaSource
    var id: String { "\(source)-\(article.id)" }
}

enum IOSActionFeedbackKind: CaseIterable, Equatable {
    case linkCopied
    case savedToService
    case noThirdPartyIntegration
    case addedToListeningList
    case removedFromListeningList
    case downloadRequested
    case downloadCancelled
    case downloadDeletionRequested

    var message: String {
        switch self {
        case .linkCopied:
            String(localized: "Link copied")
        case .savedToService:
            String(localized: "Saved to third-party service")
        case .noThirdPartyIntegration:
            String(localized: "No third-party integration is configured in Miniflux")
        case .addedToListeningList:
            String(localized: "Added to Listening List")
        case .removedFromListeningList:
            String(localized: "Removed from Listening List")
        case .downloadRequested:
            String(localized: "Download requested")
        case .downloadCancelled:
            String(localized: "Download cancelled")
        case .downloadDeletionRequested:
            String(localized: "Download deletion requested")
        }
    }

    var symbolName: String {
        switch self {
        case .linkCopied:
            "doc.on.doc"
        case .savedToService:
            "checkmark.circle.fill"
        case .noThirdPartyIntegration:
            "info.circle"
        case .addedToListeningList:
            "headphones"
        case .removedFromListeningList:
            "minus.circle"
        case .downloadRequested:
            "arrow.down.circle"
        case .downloadCancelled:
            "xmark.circle"
        case .downloadDeletionRequested:
            "trash"
        }
    }
}

struct IOSActionFeedbackItem: Equatable, Identifiable {
    let id: UInt64
    let kind: IOSActionFeedbackKind
}

enum IOSActionFeedbackPresentation {
    static let autoDismissDelay: Duration = .seconds(3)
    static let baseBottomPadding: CGFloat = 18
    static let bottomActionBarClearance: CGFloat = 54

    static func bottomPadding(hasBottomActionBar: Bool) -> CGFloat {
        baseBottomPadding
            + (hasBottomActionBar ? bottomActionBarClearance : 0)
    }

    static func shouldDismiss(
        current: IOSActionFeedbackItem?,
        id: UInt64
    ) -> Bool {
        current?.id == id
    }
}

private struct IOSActionFeedbackBanner: View {
    let item: IOSActionFeedbackItem

    var body: some View {
        Label {
            Text(item.kind.message)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: item.kind.symbolName)
                .foregroundStyle(Color.accentColor)
        }
        .font(.callout.weight(.semibold))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            ArticleListChromeCapsuleBackground(
                usesSystemToolbarGlass: false,
                isInteractive: false
            )
        }
        .overlay {
            Capsule()
                .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
        .shadow(radius: 5, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.kind.message)
        .allowsHitTesting(false)
    }
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var bootstrapper: CoreBootstrapper
    var newsreaderStore: NewsreaderStore
    @StateObject private var searchStore = IOSSearchStore()
    @StateObject private var listeningListStore = IOSListeningListStore()
    @State private var navigationPresented = false
    @State private var searchPresented = false
    /// Set while the navigation sheet is closing so that search opens once it is
    /// actually gone.
    @State private var searchPendingAfterNavigationSheet = false
    @State private var diagnosticsPresented = false
    @State private var settingsPresented = false
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var browser: IOSBrowserURL?
    @State private var articleOpenError: String?
    @State private var articleOpenGeneration = 0
    @State private var readerArticle: IOSReaderArticle?
    @State private var readerDocument: ReaderDocument?
    @State private var readerIsLoading = false
    @State private var readerErrorMessage: String?
    @State private var readerGeneration = 0
    @State private var sharePayload: IOSSharePayload?
    @State private var actionFeedback: IOSActionFeedbackItem?
    @State private var actionFeedbackGeneration: UInt64 = 0
    @State private var actionError: String?
    @State private var markReadConfirmationPresented = false
    @State private var markReadWorkflow: IOSMarkReadWorkflow = .read
    @State private var syncPresentation: IOSSyncButtonPresentation.State = .idle
    @State private var syncPresentationGeneration: UInt64 = 0
    @State private var saveToServiceFeedbackTrigger: UInt64 = 0
    @State private var pendingWidgetAction: WidgetAction?
    @State private var articleMediaPlayer: IOSArticleMediaPlayerPresentation?
    @State private var listeningListPlayerArticleID: Int64?
    @State private var articleMediaDownloadChoice: IOSArticleMediaDownloadChoice?

    /// The capsule already opens the scope chooser, so a second control for the
    /// same action would be pure redundancy.
    private var capsuleCarriesScopeAction: Bool {
        !adaptivePresentation.usesPersistentSplitNavigation
    }

    private var adaptivePresentation: AdaptivePresentation {
        AdaptivePresentationPolicy.presentation(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
    }

    private var articleListChromeMode: IOSArticleListChromeMode {
        IOSArticleListChromePresentation.mode(
            for: adaptivePresentation,
            verticalSizeClass: verticalSizeClass,
            splitColumnVisibility: splitColumnVisibility
        )
    }

    private var adaptiveSplitColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { splitColumnVisibility },
            set: { requested in
                splitColumnVisibility = AdaptiveShellTransitionPolicy.constrainedSplitColumnVisibility(
                    requested: requested,
                    presentation: adaptivePresentation
                )
            }
        )
    }

    var body: some View {
        Group {
            if case .ready = bootstrapper.state, newsreaderStore.core != nil {
                newsreader
            } else {
                StartupView(bootstrapper: bootstrapper)
            }
        }
        .overlay(alignment: .bottom) {
            actionFeedbackOverlay(
                active: !searchPresented,
                hasBottomActionBar:
                    newsreaderStore.scope != .listeningList
                        && articleListChromeMode == .compactPortrait
            )
        }
        .animation(.easeInOut(duration: 0.2), value: actionFeedback?.id)
        .sheet(isPresented: $diagnosticsPresented) { DeveloperDiagnosticsView(bootstrapper: bootstrapper) }
        // A sheet rather than a pushed destination: the timeline is the detail
        // column of a split view that collapses on a phone, and a destination
        // registered there did not activate. A sheet behaves identically in both
        // size classes and needs no sequencing against the navigation sheet.
        .sheet(isPresented: $searchPresented) {
            NavigationStack {
                searchView
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { searchPresented = false }
                        }
                    }
            }
            .overlay(alignment: .bottom) {
                actionFeedbackOverlay(
                    active: true,
                    hasBottomActionBar: false
                )
            }
            .animation(.easeInOut(duration: 0.2), value: actionFeedback?.id)
            // Only one sheet can be presented per view, so what the results open
            // has to hang off the search sheet while it is up.
            .sheet(item: gatedBrowser(active: true)) { item in IOSInAppBrowser(url: item.url) }
            .sheet(item: gatedReaderSheet(active: true)) { item in
                NavigationStack { readerView(for: item.article) }
            }
            .sheet(item: gatedShare(active: true)) { payload in IOSShareSheet(items: payload.items) }
            .sheet(
                item: gatedArticleMediaPlayer(active: true),
                onDismiss: { listeningListStore.clearShowNotes() }
            ) { presentation in
                articleMediaPlayerView(presentation)
            }
            .confirmationDialog(
                "Download Audio",
                isPresented: gatedArticleMediaDownloadPresented(active: true),
                titleVisibility: .visible
            ) {
                articleMediaDownloadButtons
            }
        }
        .sheet(item: gatedBrowser(active: !searchPresented)) { item in IOSInAppBrowser(url: item.url) }
        .sheet(item: gatedReaderSheet(active: !searchPresented)) { item in
            NavigationStack { readerView(for: item.article) }
        }
        .sheet(item: gatedShare(active: !searchPresented)) { payload in IOSShareSheet(items: payload.items) }
        .sheet(
            item: gatedArticleMediaPlayer(active: !searchPresented),
            onDismiss: { listeningListStore.clearShowNotes() }
        ) { presentation in
            articleMediaPlayerView(presentation)
        }
        .sheet(
            isPresented: Binding(
                get: {
                    !searchPresented && listeningListPlayerArticleID != nil
                },
                set: { presented in
                    if !presented {
                        listeningListPlayerArticleID = nil
                    }
                }
            ),
            onDismiss: {
                listeningListStore.clearShowNotes()
            }
        ) {
            listeningListPlayerView
        }
        .confirmationDialog(
            "Download Audio",
            isPresented: gatedArticleMediaDownloadPresented(
                active: !searchPresented
            ),
            titleVisibility: .visible
        ) {
            articleMediaDownloadButtons
        }
        .alert("Unable to Open Article", isPresented: Binding(get: { articleOpenError != nil }, set: { if !$0 { articleOpenError = nil } })) {
            Button("OK", role: .cancel) { articleOpenError = nil }
        } message: { Text(articleOpenError ?? "") }
        .alert("Action Failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .sensoryFeedback(.success, trigger: saveToServiceFeedbackTrigger)
        .confirmationDialog(markReadDialogTitle, isPresented: $markReadConfirmationPresented, titleVisibility: .visible) {
            Button(markReadDialogTitle, role: .destructive) { performMarkReadWorkflow() }
        } message: { Text("Marks all unread articles in this scope as read.") }
        .onChange(of: adaptivePresentation) { _, presentation in
            normalizeAdaptiveShell(for: presentation)
        }
        .onChange(of: searchPresented) { _, presented in
            if !presented { searchStore.invalidate() }
        }
        .onChange(of: newsreaderStore.scope) { _, scope in
            if scope == .listeningList {
                listeningListStore.reload()
            }
        }
        .onAppear { normalizeAdaptiveShell(for: adaptivePresentation) }
        .onOpenURL { url in
            handleWidgetURL(url)
        }
        .task(id: bootstrapper.coreRevision) {
            if let core = newsreaderStore.core {
                searchStore.attach(
                    to: core,
                    coreSessionExecutionCoordinator: bootstrapper.coreSessionExecutionCoordinator
                )
                listeningListStore.attach(
                    to: core,
                    coreSessionExecutionCoordinator: bootstrapper.coreSessionExecutionCoordinator
                )
                listeningListStore.onTransferReconciliationRequested = {
                    await IOSAppRuntime.shared.mediaTransferReconciliationHandoff
                        .requestReconciliation()
                }
                IOSAppRuntime.shared.mediaRuntime.transferCoordinator.onWorkChanged = {
                    listeningListStore.reload()
                }
                newsreaderStore.onMediaTransferReconciliationRequested = {
                    await IOSAppRuntime.shared.mediaTransferReconciliationHandoff
                        .requestReconciliation()
                }
                searchStore.onMediaTransferReconciliationRequested = {
                    await IOSAppRuntime.shared.mediaTransferReconciliationHandoff
                        .requestReconciliation()
                }
                searchStore.onLocalFirstMutation = { newsreaderStore.loadNavigationAndCounts() }
            } else {
                searchStore.onMediaTransferReconciliationRequested = nil
                searchStore.detach()
                listeningListStore.onTransferReconciliationRequested = nil
                IOSAppRuntime.shared.mediaRuntime.transferCoordinator.onWorkChanged = nil
                newsreaderStore.onMediaTransferReconciliationRequested = nil
                listeningListStore.detach()
            }
            consumePendingWidgetActionIfReady()
        }
    }

    private func gatedArticleMediaPlayer(
        active: Bool
    ) -> Binding<IOSArticleMediaPlayerPresentation?> {
        Binding(
            get: { active ? articleMediaPlayer : nil },
            set: { if active { articleMediaPlayer = $0 } }
        )
    }

    private func gatedArticleMediaDownloadPresented(
        active: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { active && articleMediaDownloadChoice != nil },
            set: {
                if active && !$0 {
                    articleMediaDownloadChoice = nil
                }
            }
        )
    }

    @ViewBuilder
    private var listeningListPlayerView: some View {
        let item = listeningListPlayerArticleID.flatMap { articleID in
            listeningListStore.items.first { $0.articleId == articleID }
        }

        IOSMediaPlayerView(
            playbackState: IOSAppRuntime.shared.mediaRuntime.playbackPresentationState,
            playbackCoordinator: IOSAppRuntime.shared.mediaRuntime.playbackCoordinator,
            item: item,
            showNotesDocument: listeningListStore.showNotesDocument,
            showNotesIsLoading: listeningListStore.showNotesIsLoading,
            showNotesErrorMessage: listeningListStore.showNotesErrorMessage,
            onSelectEnclosure: { enclosureID in
                if let articleID = listeningListPlayerArticleID {
                    playListeningListEnclosure(
                        articleID: articleID,
                        enclosureID: enclosureID
                    )
                }
            },
            onShowNotes: {
                if let articleID = listeningListPlayerArticleID {
                    listeningListStore.loadShowNotes(articleID: articleID)
                }
            },
            onDismiss: {
                listeningListPlayerArticleID = nil
            }
        )
    }

    private func openListeningListPlayer(articleID: Int64) {
        listeningListPlayerArticleID = articleID
        guard let item = listeningListStore.items.first(
            where: { $0.articleId == articleID }
        ) else {
            return
        }

        let playbackState = IOSAppRuntime.shared.mediaRuntime
            .playbackPresentationState
        if let loadedEnclosureID = playbackState.loadedEnclosure?.id,
           item.audioEnclosures.contains(
               where: { $0.enclosure.id == loadedEnclosureID }
           ) {
            // Opening the Player for the item that already owns the prepared or
            // playing enclosure is presentation-only. Re-preparing here would
            // reload the last persisted Core checkpoint and seek active playback
            // backwards.
            return
        }

        let preferred = IOSListeningListPresentation.selectedEnclosure(item)
            ?? item.audioEnclosures.first
        guard let enclosureID = preferred?.enclosure.id else { return }

        Task {
            do {
                _ = try await IOSAppRuntime.shared.mediaRuntime
                    .playbackCoordinator.prepare(enclosureID: enclosureID)
                listeningListStore.reload()
            } catch {
                let coordinator = IOSAppRuntime.shared.mediaRuntime
                    .playbackCoordinator
                IOSAppRuntime.shared.mediaRuntime.playbackPresentationState
                    .setErrorMessage(
                        coordinator.lastStartFailureDescription
                            ?? error.localizedDescription
                    )
            }
        }
    }

    private func playListeningListEnclosure(
        articleID: Int64,
        enclosureID: Int64
    ) {
        Task {
            do {
                try await IOSAppRuntime.shared.mediaRuntime
                    .playbackCoordinator.play(enclosureID: enclosureID)
                listeningListStore.reload()
            } catch {
                let coordinator = IOSAppRuntime.shared.mediaRuntime
                    .playbackCoordinator
                IOSAppRuntime.shared.mediaRuntime.playbackPresentationState
                    .setErrorMessage(
                        coordinator.lastStartFailureDescription
                            ?? error.localizedDescription
                    )
            }
        }
    }

    @ViewBuilder
    private func articleMediaPlayerView(
        _ presentation: IOSArticleMediaPlayerPresentation
    ) -> some View {
        IOSMediaPlayerView(
            playbackState: IOSAppRuntime.shared.mediaRuntime.playbackPresentationState,
            playbackCoordinator: IOSAppRuntime.shared.mediaRuntime.playbackCoordinator,
            item: nil,
            showNotesDocument: listeningListStore.showNotesDocument,
            showNotesIsLoading: listeningListStore.showNotesIsLoading,
            showNotesErrorMessage: listeningListStore.showNotesErrorMessage,
            onSelectEnclosure: { _ in },
            onShowNotes: {
                listeningListStore.loadShowNotes(
                    articleID: presentation.article.id
                )
            },
            onDismiss: {
                articleMediaPlayer = nil
            }
        )
    }

    @ViewBuilder
    private var articleMediaDownloadButtons: some View {
        if let choice = articleMediaDownloadChoice {
            ForEach(
                Array(choice.enclosures.enumerated()),
                id: \.element.id
            ) { index, enclosure in
                Button(
                    IOSArticleAudioPresentation.enclosureLabel(
                        enclosure,
                        index: index
                    )
                ) {
                    performArticleDownload(
                        article: choice.article,
                        enclosure: enclosure,
                        source: choice.source
                    )
                    articleMediaDownloadChoice = nil
                }
            }
        }
        Button("Cancel", role: .cancel) {
            articleMediaDownloadChoice = nil
        }
    }

    @ViewBuilder
    private var newsreader: some View {
        NavigationSplitView(columnVisibility: adaptiveSplitColumnVisibility) {
            NewsNavigationView(
                store: newsreaderStore,
                sheetPresented: $navigationPresented,
                presentation: .sidebar,
                onSearch: openSearch
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            adaptiveDetail
        }
        // These presentations outlive an article-navigation reset.
        .sheet(isPresented: $navigationPresented, onDismiss: {
            guard searchPendingAfterNavigationSheet else { return }
            searchPendingAfterNavigationSheet = false
            searchPresented = true
        }) {
            NavigationStack {
                NewsNavigationView(store: newsreaderStore, sheetPresented: $navigationPresented, presentation: .sheet, onSearch: openSearch)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { navigationPresented = false } } }
            }
        }
        .sheet(isPresented: $settingsPresented) { SettingsView(store: newsreaderStore, bootstrapper: bootstrapper, onDiagnostics: { diagnosticsPresented = true }) }
    }

    @ViewBuilder
    private var adaptiveDetail: some View {
        if newsreaderStore.scope == .listeningList {
            IOSListeningListView(
                store: listeningListStore,
                playbackState: IOSAppRuntime.shared.mediaRuntime.playbackPresentationState,
                transferState: IOSAppRuntime.shared.mediaRuntime.transferPresentationState,
                playbackCoordinator: IOSAppRuntime.shared.mediaRuntime.playbackCoordinator,
                showsScopeChooser:
                    IOSListeningListNavigationPresentation.showsScopeChooser(
                        for: adaptivePresentation,
                        splitColumnVisibility: splitColumnVisibility
                    ),
                onPresentScopeChooser: presentArticleListNavigation,
                onOpenPlayer: openListeningListPlayer,
                onPlay: playListeningListEnclosure
            )
        } else {
            articleList
                .inspector(isPresented: readerInspectorBinding) {
                    Group {
                        if usesReaderInspector, let article = readerArticle?.article {
                            NavigationStack { readerView(for: article) }
                        } else if usesReaderInspector {
                            Color.clear.onAppear { dismissReader() }
                        }
                    }
                }
                .toolbar {
                    if !adaptivePresentation.usesPersistentSplitNavigation, !capsuleCarriesScopeAction {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { navigationPresented = true } label: {
                                Image(IOSNavigationButtonPresentation.imageName)
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(
                                        width: IOSNavigationButtonPresentation.glyphSize,
                                        height: IOSNavigationButtonPresentation.glyphSize
                                    )
                            }
                            .accessibilityLabel(IOSNavigationButtonPresentation.accessibilityLabel)
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var articleList: some View {
#if FLUX_HAS_VERTICAL_TOOLBAR_API
        if #available(iOS 27.1, *) {
            IOSArticleListVerticalToolbarEnvironment { systemPrefersVerticalToolbar in
                articleList(systemPrefersVerticalToolbar: systemPrefersVerticalToolbar)
            }
        } else {
            articleList(systemPrefersVerticalToolbar: false)
        }
#else
        articleList(systemPrefersVerticalToolbar: false)
#endif
    }

    private func articleList(systemPrefersVerticalToolbar: Bool) -> some View {
        let actionPlacement = IOSArticleListChromePresentation.actionPlacement(
            for: articleListChromeMode,
            systemPrefersVerticalToolbar: systemPrefersVerticalToolbar
        )
        let usesNativeTopEdgeEffect = IOSArticleListChromePresentation.usesNativeTopEdgeEffect(
            for: articleListChromeMode,
            systemPrefersVerticalToolbar: systemPrefersVerticalToolbar
        )

        return ArticleListNavigationChrome(
            store: newsreaderStore,
            onSelectScope: presentArticleListNavigation,
            chromeMode: articleListChromeMode,
            actionPlacement: actionPlacement,
            topActions: {
                articleListActionButtons
            },
            content: { naturalTopContentInset in
                ArticleListView(
                    store: newsreaderStore,
                    naturalTopContentInset: naturalTopContentInset,
                    usesNativeTopEdgeEffect: usesNativeTopEdgeEffect,
                    onArticleTap: openArticle,
                    onArticleAction: handleArticleAction,
                    onArticleMediaAction: handleArticleMediaAction
                )
            }
        )
            .navigationBarTitleDisplayMode(IOSArticleNavigationPresentation.titleDisplayMode)
            .toolbar(
                IOSArticleListChromePresentation.showsTopNavigationBar(
                    for: articleListChromeMode,
                    systemPrefersVerticalToolbar: systemPrefersVerticalToolbar
                ) ? .visible : .hidden,
                for: .navigationBar
            )
            // A collapsed split view pushes the detail and offers a back button.
            // The Timeline is the root of this app's navigation: the branded
            // button opens the scope chooser, there is nothing to go back to.
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if actionPlacement == .bottomBar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        articleListActionButtons
                    }
                }
                if actionPlacement == .topBarTrailing {
                    if #available(iOS 26.0, *) {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            articleListActionButtons
                        }
                    } else {
                        ToolbarItem(placement: .topBarTrailing) {
                            HStack(spacing: IOSArticleListActionChromeMetrics.floatingSpacing) {
                                articleListActionButtons
                            }
                            .padding(.horizontal, IOSArticleListActionChromeMetrics.floatingHorizontalPadding)
                            .padding(.vertical, IOSArticleListActionChromeMetrics.floatingVerticalPadding)
                            .background(.regularMaterial, in: Capsule())
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var articleListActionButtons: some View {
        let syncButtonPresentation = IOSSyncButtonPresentation.resolve(
            manualSyncState: newsreaderStore.manualSyncState,
            transientState: syncPresentation
        )
        Button { performManualSyncControlAction() } label: {
            Image(systemName: IOSSyncButtonPresentation.symbolName(for: syncButtonPresentation))
                .frame(width: 24, height: 24)
        }
        .accessibilityLabel(IOSSyncButtonPresentation.accessibilityLabel(for: syncButtonPresentation))
        .accessibilityValue(IOSSyncButtonPresentation.accessibilityValue(for: syncButtonPresentation))
        .accessibilityIdentifier("articleList.sync")

        Menu {
            Section("Show") {
                Button { newsreaderStore.setUnreadOnly(true) } label: {
                    filterMenuLabel(String(localized: "Unread Only"), selected: newsreaderStore.unreadOnly)
                }
                Button { newsreaderStore.setUnreadOnly(false) } label: {
                    filterMenuLabel(String(localized: "All Articles"), selected: !newsreaderStore.unreadOnly)
                }
            }
            Section("Sort") {
                Button { newsreaderStore.setNewestFirst(true) } label: {
                    filterMenuLabel(String(localized: "Newest First"), selected: newsreaderStore.newestFirst)
                }
                Button { newsreaderStore.setNewestFirst(false) } label: {
                    filterMenuLabel(String(localized: "Oldest First"), selected: !newsreaderStore.newestFirst)
                }
            }
        } label: {
            Label("Filter and Sort", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("articleList.filterSort")

        Menu {
            ForEach(IOSMoreAction.actions(for: newsreaderStore.scope, hasNextScope: nextScope != nil), id: \.self) { action in
                switch action {
                case .markAllRead:
                    Button("Mark All as Read", role: .destructive) { presentMarkReadConfirmation(.read) }
                case .markAllReadAndNext:
                    Button("Mark All as Read and Continue", role: .destructive) { presentMarkReadConfirmation(.readAndNext) }
                case .settings:
                    Divider()
                    Button { settingsPresented = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel(String(localized: "More"))
        .accessibilityIdentifier("articleList.more")
    }

    private func presentArticleListNavigation() {
        if adaptivePresentation.usesPersistentSplitNavigation {
            splitColumnVisibility = .all
        } else {
            navigationPresented = true
        }
    }

    private func performManualSyncControlAction() {
        switch newsreaderStore.manualSyncState {
        case .running:
            syncPresentationGeneration &+= 1
            syncPresentation = .idle
            newsreaderStore.cancelManualSync()
        case .idle, .cancelling:
            Task { await performManualSync() }
        }
    }

    private func performManualSync() async {
        syncPresentationGeneration &+= 1
        let generation = syncPresentationGeneration
        syncPresentation = .idle

        await newsreaderStore.syncManually()

        guard IOSSyncButtonPresentation.canEndSuccess(
            generation: generation,
            currentGeneration: syncPresentationGeneration,
            isSyncing: newsreaderStore.isSyncing
        ) else { return }
        guard newsreaderStore.errorMessage == nil else {
            syncPresentation = .idle
            return
        }

        syncPresentation = .success
        do {
            try await Task.sleep(for: .milliseconds(1500))
        } catch {
            return
        }
        guard IOSSyncButtonPresentation.canEndSuccess(
            generation: generation,
            currentGeneration: syncPresentationGeneration,
            isSyncing: newsreaderStore.isSyncing
        ) else { return }
        syncPresentation = .idle
    }

    private var searchView: some View {
        SearchView(
            store: searchStore,
            newsreaderStore: newsreaderStore,
            onArticleTap: openSearchArticle,
            onArticleAction: handleSearchArticleAction,
            onArticleMediaAction: handleSearchArticleMediaAction,
            onSetRead: { article, read in
                searchStore.setRead(article, read: read)
            },
            onSetStarred: { article, starred in
                searchStore.setStarred(article, starred: starred)
            }
        )
    }

    @ViewBuilder
    private func actionFeedbackOverlay(
        active: Bool,
        hasBottomActionBar: Bool
    ) -> some View {
        if active, let feedback = actionFeedback {
            IOSActionFeedbackBanner(item: feedback)
                .padding(.horizontal, 16)
                .safeAreaPadding(
                    .bottom,
                    IOSActionFeedbackPresentation.bottomPadding(
                        hasBottomActionBar: hasBottomActionBar
                    )
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: feedback.id) {
                    do {
                        try await Task.sleep(
                            for: IOSActionFeedbackPresentation.autoDismissDelay
                        )
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          IOSActionFeedbackPresentation.shouldDismiss(
                            current: actionFeedback,
                            id: feedback.id
                          ) else {
                        return
                    }
                    actionFeedback = nil
                }
        }
    }

    private func showActionFeedback(_ kind: IOSActionFeedbackKind) {
        actionFeedbackGeneration &+= 1
        actionFeedback = IOSActionFeedbackItem(
            id: actionFeedbackGeneration,
            kind: kind
        )
    }

    private func openSearch() {
        // Presenting while the navigation sheet is still dismissing loses the
        // presentation, so its dismissal callback performs it.
        guard navigationPresented else {
            searchPresented = true
            return
        }
        searchPendingAfterNavigationSheet = true
        navigationPresented = false
    }

    private func normalizeAdaptiveShell(for presentation: AdaptivePresentation) {
        navigationPresented = AdaptiveShellTransitionPolicy.navigationSheetPresented(
            after: presentation,
            wasPresented: navigationPresented
        )
        splitColumnVisibility = AdaptiveShellTransitionPolicy.splitColumnVisibility(after: presentation)
    }

    private func handleWidgetURL(_ url: URL) {
        guard let action = WidgetAction(url: url) else { return }
        guard newsreaderStore.core != nil else {
            pendingWidgetAction = action
            return
        }
        performWidgetAction(action)
    }

    private func performWidgetAction(_ action: WidgetAction) {
        switch action {
        case let .article(articleID):
            newsreaderStore.article(withID: articleID) { article in
                guard let article else { return }
                openArticle(article)
            }
        case let .open(selection):
            newsreaderStore.openWidgetScope(selection)
        case .sync:
            newsreaderStore.syncFromWidget()
        }
    }

    private func consumePendingWidgetActionIfReady() {
        guard newsreaderStore.core != nil, let action = pendingWidgetAction else { return }
        pendingWidgetAction = nil
        performWidgetAction(action)
    }

    private func openArticle(_ article: ArticleSummary) {
        switch ArticleOpenRouting.action(clickOnNews: newsreaderStore.clickOnNews, openInMiniflux: false) {
        case .detail:
            openReader(article)
            return
        case .original, .miniflux:
            openOriginalArticle(article)
            return
        }
    }

    private func openOriginalArticle(_ article: ArticleSummary) {
        articleOpenGeneration += 1
        let generation = articleOpenGeneration
        newsreaderStore.open(article) { original in
            guard let url = ArticleOpenRoutingPolicy.validWebURL(original) else {
                present(.invalid)
                return
            }
            UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { succeeded in
                Task { @MainActor in
                    guard generation == articleOpenGeneration else { return }
                    present(ArticleOpenRoutingPolicy.destination(originalURL: original, universalLinkSucceeded: succeeded))
                }
            }
        }
    }

    private func openSearchArticle(_ article: ArticleSummary) {
        switch ArticleOpenRouting.action(clickOnNews: newsreaderStore.clickOnNews, openInMiniflux: false) {
        case .detail: openSearchReader(article)
        case .original, .miniflux: openSearchOriginalArticle(article)
        }
    }

    private func openSearchOriginalArticle(_ article: ArticleSummary) {
        articleOpenGeneration += 1
        let generation = articleOpenGeneration
        searchStore.open(article) { original in
            guard let url = ArticleOpenRoutingPolicy.validWebURL(original) else {
                present(.invalid)
                return
            }
            UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { succeeded in
                Task { @MainActor in
                    guard generation == articleOpenGeneration else { return }
                    present(ArticleOpenRoutingPolicy.destination(originalURL: original, universalLinkSucceeded: succeeded))
                }
            }
        }
    }

    private func handleArticleAction(_ article: ArticleSummary, _ action: IOSArticleContextAction) {
        switch action {
        case .starred:
            newsreaderStore.setStarred(article, starred: !article.isStarred)
        case .read:
            newsreaderStore.setRead(article, read: !article.isRead)
        case .original:
            openOriginalArticle(article)
        case .reader:
            openReader(article)
        case .miniflux:
            newsreaderStore.minifluxEntryURL(for: article) { result in
                switch result {
                case let .success(value):
                    guard let url = ArticleOpenRoutingPolicy.validWebURL(value) else {
                         actionError = String(localized: "Flux could not resolve a valid Miniflux entry URL.")
                        return
                    }
                    browser = IOSBrowserURL(url: url)
                case let .failure(error): actionError = IOSErrorPresentation.message(for: error, context: .articleAction)
                }
            }
        case .comments:
            guard let url = IOSArticleContextMenuPolicy.commentsURL(article.commentsUrl) else { return }
            browser = IOSBrowserURL(url: url)
        case .copyLink:
            UIPasteboard.general.string = article.url
             showActionFeedback(.linkCopied)
        case .share:
            guard let url = IOSArticleContextMenuPolicy.originalURL(article.url) else {
                 actionError = String(localized: "The article does not have a valid web URL.")
                return
            }
            sharePayload = IOSSharePayload(items: [article.title, url])
        case .saveToService:
            newsreaderStore.saveToService(article) { result in
                switch result {
                case let .success(value):
                    if IOSArticleActionHapticPolicy.shouldConfirmSaveToService(value) {
                        saveToServiceFeedbackTrigger &+= 1
                    }
                    switch value {
                    case .saved:
                        showActionFeedback(.savedToService)
                    case .noIntegrationConfigured:
                        showActionFeedback(.noThirdPartyIntegration)
                    }
                case let .failure(error):
                    actionError = IOSErrorPresentation.message(for: error, context: .articleAction)
                }
            }
        }
    }

    private func handleArticleMediaAction(
        _ article: ArticleSummary,
        _ action: IOSArticleMediaAction
    ) {
        switch action {
        case let .play(enclosureID):
            articleMediaPlayer = .init(
                article: article,
                enclosureID: enclosureID
            )
            Task {
                do {
                    try await IOSAppRuntime.shared.mediaRuntime
                        .playbackCoordinator.play(enclosureID: enclosureID)
                } catch {
                    let coordinator = IOSAppRuntime.shared.mediaRuntime
                        .playbackCoordinator
                    actionError = coordinator.lastStartFailureDescription
                        ?? error.localizedDescription
                    articleMediaPlayer = nil
                }
            }

        case let .setListeningList(enabled):
            Task {
                let result = await newsreaderStore
                    .setArticleListeningListMembership(
                        articleID: article.id,
                        isInListeningList: enabled
                    )
                presentArticleMediaMutationResult(
                    result,
                    success: enabled
                        ? .addedToListeningList
                        : .removedFromListeningList
                )
            }

        case let .requestDownload(enclosureID):
            Task {
                let result = await newsreaderStore.requestArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosureID
                )
                presentArticleMediaMutationResult(
                    result,
                    success: .downloadRequested
                )
            }

        case let .cancelDownload(enclosureID):
            Task {
                let result = await newsreaderStore.cancelArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosureID
                )
                presentArticleMediaMutationResult(
                    result,
                    success: .downloadCancelled
                )
            }

        case let .retryDownload(enclosureID):
            Task {
                let result = await newsreaderStore.retryArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosureID
                )
                presentArticleMediaMutationResult(
                    result,
                    success: .downloadRequested
                )
            }

        case let .deleteDownload(enclosureID):
            Task {
                let result = await newsreaderStore.deleteArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosureID
                )
                presentArticleMediaMutationResult(
                    result,
                    success: .downloadDeletionRequested
                )
            }

        case .configuredDownloadAudio:
            let enclosures = IOSArticleAudioPresentation.downloadableEnclosures(
                newsreaderStore.articleAudioActionStates[article.id]
            )
            if enclosures.count == 1, let enclosure = enclosures.first {
                performArticleDownload(
                    article: article,
                    enclosure: enclosure,
                    source: .news
                )
            } else if !enclosures.isEmpty {
                articleMediaDownloadChoice = .init(
                    article: article,
                    enclosures: enclosures,
                    source: .news
                )
            }
        }
    }

    private func performArticleDownload(
        article: ArticleSummary,
        enclosure: Enclosure,
        source: IOSArticleMediaSource
    ) {
        let state = switch source {
        case .news:
            newsreaderStore.articleAudioActionStates[article.id]
        case .search:
            searchStore.articleAudioActionStates[article.id]
        }
        let action = IOSArticleAudioPresentation.downloadAction(
            state?.downloads[enclosure.id]
        )

        Task {
            let result: Result<Void, Error>
            switch (source, action) {
            case (.news, .retry):
                result = await newsreaderStore.retryArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosure.id
                )
            case (.news, .download):
                result = await newsreaderStore.requestArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosure.id
                )
            case (.search, .retry):
                result = await searchStore.retryArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosure.id
                )
            case (.search, .download):
                result = await searchStore.requestArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosure.id
                )
            case (_, .pending), (_, .delete), (_, .pendingDeletion):
                return
            }
            presentArticleMediaMutationResult(
                result,
                success: .downloadRequested
            )
        }
    }

    private func presentArticleMediaMutationResult(
        _ result: Result<Void, Error>,
        success: IOSActionFeedbackKind
    ) {
        switch result {
        case .success:
            showActionFeedback(success)
        case let .failure(error):
            actionError = IOSErrorPresentation.message(
                for: error,
                context: .articleAction
            )
        }
    }

    private func handleSearchArticleMediaAction(
        _ article: ArticleSummary,
        _ action: IOSArticleMediaAction
    ) {
        switch action {
        case let .play(enclosureID):
            articleMediaPlayer = .init(
                article: article,
                enclosureID: enclosureID
            )
            Task {
                do {
                    try await IOSAppRuntime.shared.mediaRuntime
                        .playbackCoordinator.play(enclosureID: enclosureID)
                } catch {
                    let coordinator = IOSAppRuntime.shared.mediaRuntime
                        .playbackCoordinator
                    actionError = coordinator.lastStartFailureDescription
                        ?? error.localizedDescription
                    articleMediaPlayer = nil
                }
            }

        case let .setListeningList(enabled):
            Task {
                let result = await searchStore
                    .setArticleListeningListMembership(
                        articleID: article.id,
                        isInListeningList: enabled
                    )
                presentArticleMediaMutationResult(
                    result,
                    success: enabled
                        ? .addedToListeningList
                        : .removedFromListeningList
                )
            }

        case let .requestDownload(enclosureID):
            Task {
                let result = await searchStore.requestArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosureID
                )
                presentArticleMediaMutationResult(
                    result,
                    success: .downloadRequested
                )
            }

        case let .cancelDownload(enclosureID):
            Task {
                let result = await searchStore.cancelArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosureID
                )
                presentArticleMediaMutationResult(
                    result,
                    success: .downloadCancelled
                )
            }

        case let .retryDownload(enclosureID):
            Task {
                let result = await searchStore.retryArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosureID
                )
                presentArticleMediaMutationResult(
                    result,
                    success: .downloadRequested
                )
            }

        case let .deleteDownload(enclosureID):
            Task {
                let result = await searchStore.deleteArticleDownload(
                    articleID: article.id,
                    enclosureID: enclosureID
                )
                presentArticleMediaMutationResult(
                    result,
                    success: .downloadDeletionRequested
                )
            }

        case .configuredDownloadAudio:
            let enclosures = IOSArticleAudioPresentation.downloadableEnclosures(
                searchStore.articleAudioActionStates[article.id]
            )
            if enclosures.count == 1, let enclosure = enclosures.first {
                performArticleDownload(
                    article: article,
                    enclosure: enclosure,
                    source: .search
                )
            } else if !enclosures.isEmpty {
                articleMediaDownloadChoice = .init(
                    article: article,
                    enclosures: enclosures,
                    source: .search
                )
            }
        }
    }

    private func handleSearchArticleAction(_ article: ArticleSummary, _ action: IOSArticleContextAction) {
        switch action {
        case .starred: searchStore.setStarred(article, starred: !article.isStarred)
        case .read: searchStore.setRead(article, read: !article.isRead)
        case .original: openSearchOriginalArticle(article)
        case .reader: openSearchReader(article)
        case .miniflux: openMiniflux(article, using: searchStore)
        case .comments:
            guard let url = IOSArticleContextMenuPolicy.commentsURL(article.commentsUrl) else { return }
            browser = IOSBrowserURL(url: url)
        case .copyLink:
            UIPasteboard.general.string = article.url
             showActionFeedback(.linkCopied)
        case .share:
             guard let url = IOSArticleContextMenuPolicy.originalURL(article.url) else { actionError = String(localized: "The article does not have a valid web URL."); return }
            sharePayload = IOSSharePayload(items: [article.title, url])
        case .saveToService:
            searchStore.saveToService(article) { result in
                switch result {
                case let .success(value):
                    if IOSArticleActionHapticPolicy.shouldConfirmSaveToService(value) {
                        saveToServiceFeedbackTrigger &+= 1
                    }
                    switch value {
                    case .saved:
                        showActionFeedback(.savedToService)
                    case .noIntegrationConfigured:
                        showActionFeedback(.noThirdPartyIntegration)
                    }
                case let .failure(error):
                    actionError = IOSErrorPresentation.message(for: error, context: .articleAction)
                }
            }
        }
    }

    private func openMiniflux(_ article: ArticleSummary, using store: IOSSearchStore) {
        store.minifluxEntryURL(for: article) { result in
            switch result {
            case let .success(value):
                guard let url = ArticleOpenRoutingPolicy.validWebURL(value) else { actionError = String(localized: "Flux could not resolve a valid Miniflux entry URL."); return }
                browser = IOSBrowserURL(url: url)
            case let .failure(error): actionError = IOSErrorPresentation.message(for: error, context: .articleAction)
            }
        }
    }

    private func openReader(_ article: ArticleSummary) {
        readerGeneration += 1
        let generation = readerGeneration
        readerArticle = IOSReaderArticle(article: article)
        readerDocument = nil
        readerErrorMessage = nil
        readerIsLoading = true
        newsreaderStore.openReader(article) { result in
            guard generation == readerGeneration else { return }
            readerIsLoading = false
            switch result {
            case let .success(document): readerDocument = document
            case let .failure(error): readerErrorMessage = IOSErrorPresentation.message(for: error, context: .reader)
            }
        }
    }

    private func openSearchReader(_ article: ArticleSummary) {
        readerGeneration += 1
        let generation = readerGeneration
        readerArticle = IOSReaderArticle(article: article)
        readerDocument = nil
        readerErrorMessage = nil
        readerIsLoading = true
        searchStore.openReader(article) { result in
            guard generation == readerGeneration else { return }
            readerIsLoading = false
            switch result {
            case let .success(document): readerDocument = document
            case let .failure(error): readerErrorMessage = IOSErrorPresentation.message(for: error, context: .reader)
            }
        }
    }

    private func present(_ destination: ArticleOpenDestination) {
        switch destination {
        case .universalLink: break
        case .browser(let url): browser = IOSBrowserURL(url: url)
        case .invalid: articleOpenError = String(localized: "The article does not have a valid web URL.")
        }
    }

    @ViewBuilder
    private func filterMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") }
        else { Text(title) }
    }

    private var markReadDialogTitle: String {
        markReadWorkflow == .readAndNext ? String(localized: "Mark All as Read and Continue") : String(localized: "Mark All as Read")
    }

    private var nextScope: BrowserScope? {
        IOSScopeNavigation.nextScope(
            after: newsreaderStore.scope,
            catalog: newsreaderStore.catalog,
            hidingEmpty: newsreaderStore.hideEmptyNavigationEntries,
            counts: newsreaderStore.feedCounts
        )
    }

    private func presentMarkReadConfirmation(_ workflow: IOSMarkReadWorkflow) {
        markReadWorkflow = workflow
        markReadConfirmationPresented = true
    }

    private func performMarkReadWorkflow() {
        let target = markReadWorkflow == .readAndNext ? nextScope : nil
        newsreaderStore.markCurrentScopeAsRead { succeeded in
            guard succeeded, let target else { return }
            newsreaderStore.select(target)
        }
    }
}

private enum ArticleListTitleCapsuleLayout: Equatable {
    case stacked
    case compactStacked
    case inline
}

private struct ArticleListTitleCapsule: View {
    let title: String
    let subtitle: String?
    let widthReservationSubtitle: String?
    let layout: ArticleListTitleCapsuleLayout
    var action: (() -> Void)?
    var usesSystemToolbarGlass = false
    // Read so the derived glyph height is recomputed when the text size changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The combined height of the two lines, from the same font metrics that lay
    /// them out. A fixed point size would drift apart from them under Dynamic
    /// Type, and a flexible frame would let the glyph drive the capsule's height.
    private var glyphHeight: CGFloat {
        switch layout {
        case .stacked:
            let titleHeight = UIFont.preferredFont(forTextStyle: .headline).lineHeight
            guard subtitle != nil else { return titleHeight }
            return titleHeight + 1 + UIFont.preferredFont(forTextStyle: .caption1).lineHeight
        case .compactStacked:
            return UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        case .inline:
            return UIFont.preferredFont(forTextStyle: .headline).lineHeight
        }
    }

    private var horizontalSpacing: CGFloat {
        layout == .compactStacked ? IOSArticleListTitleCapsuleMetrics.compactStackedSpacing : 8
    }

    private var horizontalPadding: CGFloat {
        if layout == .compactStacked {
            return IOSArticleListTitleCapsuleMetrics.compactStackedHorizontalPadding
        }
        return action == nil ? 16 : 12
    }

    var body: some View {
        // This capsule replaced the navigation title, so it has to carry that
        // role too: the label is what the screen *is* (the scope), the value is
        // its state, and the hint is what tapping does. Announcing the action as
        // the label would put the least useful part first.
        //
        // `.isHeader` restores what `.navigationTitle("")` gave up — without it
        // VoiceOver's heading rotor finds nothing on this screen.
        if let action {
            Button(action: action) { capsule }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(subtitle ?? "")
                .accessibilityHint(IOSNavigationButtonPresentation.accessibilityLabel)
                .accessibilityAddTraits(.isHeader)
        } else {
            // No action on a persistent sidebar, but the two lines would still be
            // read as separate, role-less elements without this.
            capsule
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(subtitle ?? "")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var capsule: some View {
        HStack(spacing: horizontalSpacing) {
            if action != nil {
                Image(IOSNavigationButtonPresentation.imageName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: glyphHeight, height: glyphHeight)
                    // `.plain` hands its content the label colour. The brand mark
                    // keeps the accent it had as a standalone button.
                    .foregroundStyle(Color.accentColor)
            }
            titleAndSubtitle
            if action != nil {
                // Glass says "interactive", the chevron says what kind. No
                // explicit colour: an inherited one still flips with the glass
                // over dark content, a semantic one would not.
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.55)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            ArticleListChromeCapsuleBackground(
                usesSystemToolbarGlass: usesSystemToolbarGlass,
                isInteractive: action != nil
            )
        }
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }

    private var verticalPadding: CGFloat {
        switch layout {
        case .stacked: IOSArticleListTitleCapsuleMetrics.stackedVerticalPadding
        case .compactStacked: IOSArticleListTitleCapsuleMetrics.compactStackedVerticalPadding
        case .inline: 5
        }
    }

    @ViewBuilder
    private var titleAndSubtitle: some View {
        switch layout {
        case .stacked:
            VStack(spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
            }
        case .compactStacked:
            VStack(alignment: .leading, spacing: 0) {
                // Prefer the full one-line scope title when the landscape toolbar
                // can accommodate it. Only fall back to truncation when the
                // trailing action group actually needs that space.
                ViewThatFits(in: .horizontal) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.primary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                }
                .layoutPriority(IOSArticleListTitleCapsuleMetrics.compactStackedTitlePriority)
                if let subtitle {
                    ZStack(alignment: .leading) {
                        Text(subtitle)
                            .foregroundStyle(.primary)
                        if let widthReservationSubtitle {
                            Text(widthReservationSubtitle)
                                .hidden()
                        }
                    }
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                }
            }
            .frame(
                minWidth: IOSArticleListTitleCapsuleMetrics.compactStackedMinimumContentWidth,
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(IOSArticleListTitleCapsuleMetrics.compactStackedTitlePriority)
        case .inline:
            HStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(IOSArticleListTitleCapsuleMetrics.inlineTitlePriority)
                if let subtitle {
                    HStack(spacing: 4) {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(subtitle)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    // Keep the semantic count intact. On a constrained toolbar
                    // the scope/feed title truncates before the count does.
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(IOSArticleListTitleCapsuleMetrics.inlineCountPriority)
                }
            }
            // Let the title use its natural width. The navigation bar already
            // knows how much room the trailing Sync/Filter/More group needs, so
            // an app-level maximum would only cause premature truncation on wide
            // landscape phones.
            .frame(
                minWidth: IOSArticleListTitleCapsuleMetrics.inlineMinimumContentWidth,
                alignment: .leading
            )
        }
    }
}

private struct ArticleListChromeCapsuleBackground: View {
    var usesSystemToolbarGlass = false
    var isInteractive = false

    /// Whether the system is asked to avoid see-through backgrounds. Glass is
    /// exactly that, and the title has to stay legible over scrolling articles,
    /// so this substitutes an opaque fill rather than trusting the effect to
    /// adapt on its own.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *), usesSystemToolbarGlass {
            Color.clear
        } else if reduceTransparency {
            Capsule().fill(Color(uiColor: .secondarySystemBackground))
        } else if #available(iOS 26.0, *) {
            ArticleListGlassCapsule(isInteractive: isInteractive)
        } else {
            Capsule().fill(.regularMaterial)
        }
    }
}

@available(iOS 26.0, *)
private struct ArticleListGlassCapsule: UIViewRepresentable {
    let isInteractive: Bool

    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = isInteractive
        let view = UIVisualEffectView(effect: effect)
        // Resolves the capsule shape without a mask layer.
        view.cornerConfiguration = .capsule()
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = isInteractive
        uiView.effect = effect
    }

    /// A `UIVisualEffectView` has no useful intrinsic size, so the representable
    /// has to answer for it. Returning the proposal unchanged also returns
    /// `.infinity` when the container offers unbounded space, and the effect then
    /// claims everything it is given — which is how a capsule background can end
    /// up as a full-height panel. Unbounded proposals collapse to zero instead;
    /// as a background it is always handed the concrete foreground size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIVisualEffectView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: .zero)
        return CGSize(
            width: size.width.isFinite ? size.width : 0,
            height: size.height.isFinite ? size.height : 0
        )
    }
}

enum ArticleListTitlePresentation {
    static func title(scope: BrowserScope, catalog: NavigationCatalog) -> String {
        scopeTitle(scope: scope, catalog: catalog)
    }

    private static func scopeTitle(scope: BrowserScope, catalog: NavigationCatalog) -> String {
        switch scope {
        case .all: String(localized: "All News")
        case .starred: String(localized: "Starred")
        case .category(let id): catalog.categories.first { $0.id == id }?.title ?? String(localized: "Category")
        case .feed(let id): catalog.feeds.first { $0.id == id }?.title ?? String(localized: "Feed")
        case .search: String(localized: "Search")
        case .listeningList: String(localized: "Listening List")
        }
    }
}

enum ArticleListCounterPresentation {
    static func inlineLandscapeLabel(
        scope: BrowserScope,
        unreadOnly: Bool,
        count: UInt64,
        locale: Locale = .current
    ) -> String {
        if unreadOnly && scope != .starred {
            return String(localized: "\(Int(count)) unread", locale: locale)
        }
        return String(localized: "\(Int(count)) article", locale: locale)
    }

    static func isVisible(showArticleCount: Bool) -> Bool { showArticleCount }
    static func usesNativeSubtitle(showArticleCount: Bool, supportsNativeSubtitle: Bool) -> Bool {
        showArticleCount && supportsNativeSubtitle
    }
    static func usesToolbarFallback(showArticleCount: Bool, supportsNativeSubtitle: Bool) -> Bool {
        showArticleCount && !supportsNativeSubtitle
    }

    static func expandedLabel(scope: BrowserScope, unreadOnly: Bool, count: UInt64, locale: Locale = .current) -> String {
        if unreadOnly && scope != .starred {
            return String(localized: "\(Int(count)) unread article", locale: locale)
        }
        return String(localized: "\(Int(count)) article", locale: locale)
    }
}

enum IOSSyncButtonPresentation {
    enum State: Equatable {
        case idle
        case syncing
        case cancelling
        case success
    }

    static func resolve(
        manualSyncState: IOSManualSyncState,
        transientState: State
    ) -> State {
        switch manualSyncState {
        case .idle: transientState
        case .running: .syncing
        case .cancelling: .cancelling
        }
    }

    static func symbolName(for state: State) -> String {
        switch state {
        case .syncing: "xmark"
        case .success: "checkmark"
        case .idle, .cancelling: "arrow.clockwise"
        }
    }

    static func accessibilityLabel(for state: State) -> String {
        state == .syncing
            ? String(localized: "Cancel sync")
            : String(localized: "Sync news")
    }

    static func accessibilityValue(for state: State) -> String {
        switch state {
        case .idle: String(localized: "Ready")
        case .syncing: String(localized: "Syncing")
        case .cancelling: String(localized: "Cancelling")
        case .success: String(localized: "Sync complete")
        }
    }

    static func canEndSuccess(generation: UInt64, currentGeneration: UInt64, isSyncing: Bool) -> Bool {
        generation == currentGeneration && !isSyncing
    }
}

private struct ArticleListFloatingActionGroup<Actions: View>: View {
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: IOSArticleListActionChromeMetrics.floatingSpacing) {
            actions()
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, IOSArticleListActionChromeMetrics.floatingHorizontalPadding)
        .padding(.vertical, IOSArticleListActionChromeMetrics.floatingVerticalPadding)
        .background { ArticleListChromeCapsuleBackground() }
        .fixedSize()
    }
}

private struct ArticleListDetachedTopChromeHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ArticleListNavigationChrome<Content: View, TopActions: View>: View {
    var store: NewsreaderStore
    /// Absent when a persistent sidebar already offers scope selection.
    var onSelectScope: (() -> Void)?
    var chromeMode: IOSArticleListChromeMode
    var actionPlacement: IOSArticleListActionPlacement
    @ViewBuilder let topActions: () -> TopActions
    @ViewBuilder let content: (CGFloat) -> Content
    @State private var detachedTopChromeHeight: CGFloat = 0

    private func capsuleSubtitle(_ subtitle: String) -> String? {
        ArticleListCounterPresentation.usesNativeSubtitle(showArticleCount: store.showArticleCount, supportsNativeSubtitle: true) ? subtitle : nil
    }

    var body: some View {
        let title = ArticleListTitlePresentation.title(scope: store.scope, catalog: store.catalog)
        let countLabel = ArticleListCounterPresentation.expandedLabel(
            scope: store.scope,
            unreadOnly: store.unreadOnly,
            count: store.selectionTotal
        )
        let portraitSubtitle = store.isSyncing ? String(localized: "Syncing…") : countLabel
        let landscapeCountLabel = ArticleListCounterPresentation.inlineLandscapeLabel(
            scope: store.scope,
            unreadOnly: store.unreadOnly,
            count: store.selectionTotal
        )
        let syncingLabel = String(localized: "Syncing…")
        let landscapeSubtitle = store.isSyncing ? syncingLabel : landscapeCountLabel
        // Reserve the alternate second-line state so Count -> Syncing -> Count
        // does not make the compact landscape capsule breathe horizontally.
        let landscapeWidthReservationSubtitle = store.isSyncing ? landscapeCountLabel : syncingLabel

        let capsulePlacement = IOSArticleListChromePresentation.titleCapsulePlacement(for: chromeMode)
        let naturalTopContentInset: CGFloat = if chromeMode == .compactPortrait {
            detachedTopChromeHeight > 0
                ? detachedTopChromeHeight
                : IOSArticleListTitleCapsuleMetrics.portraitNaturalTopContentInset(
                    showSubtitle: store.showArticleCount
                )
        } else {
            0
        }

        // Keep the Timeline itself outside the chrome-mode switch. Compact
        // portrait and persistent split modes retain detached safe-area chrome;
        // compact iPhone landscape deliberately returns to UINavigationBar.
        content(naturalTopContentInset)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                switch (capsulePlacement, actionPlacement, chromeMode) {
                case (.floatingTopCenter, .bottomBar, .compactPortrait):
                    ArticleListTitleCapsule(
                        title: title,
                        subtitle: capsuleSubtitle(portraitSubtitle),
                        widthReservationSubtitle: nil,
                        layout: .stacked,
                        action: onSelectScope
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, IOSArticleListTitleCapsuleMetrics.floatingHorizontalInset)
                    .padding(.vertical, IOSArticleListTitleCapsuleMetrics.floatingVerticalInset)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ArticleListDetachedTopChromeHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
                case (.hidden, .floatingTopTrailing, .persistentSplit):
                    HStack {
                        Spacer(minLength: 0)
                        ArticleListFloatingActionGroup(actions: topActions)
                    }
                    .padding(.horizontal, IOSArticleListTitleCapsuleMetrics.floatingHorizontalInset)
                    .padding(.vertical, IOSArticleListTitleCapsuleMetrics.floatingVerticalInset)
                case (.floatingTopLeading, .floatingTopTrailing, .persistentSplitCollapsed):
                    HStack(spacing: IOSArticleListTitleCapsuleMetrics.floatingRowSpacing) {
                        ArticleListTitleCapsule(
                            title: title,
                            subtitle: capsuleSubtitle(landscapeSubtitle),
                            widthReservationSubtitle: nil,
                            layout: .inline,
                            action: onSelectScope
                        )
                        Spacer(minLength: IOSArticleListTitleCapsuleMetrics.floatingRowSpacing)
                        ArticleListFloatingActionGroup(actions: topActions)
                    }
                    .padding(.horizontal, IOSArticleListTitleCapsuleMetrics.floatingHorizontalInset)
                    .padding(.vertical, IOSArticleListTitleCapsuleMetrics.floatingVerticalInset)
                case (.floatingTopLeading, .topBarTrailing, .persistentSplitCollapsed):
                    ArticleListTitleCapsule(
                        title: title,
                        subtitle: capsuleSubtitle(landscapeSubtitle),
                        widthReservationSubtitle: nil,
                        layout: .inline,
                        action: onSelectScope
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IOSArticleListTitleCapsuleMetrics.floatingHorizontalInset)
                    .padding(.vertical, IOSArticleListTitleCapsuleMetrics.floatingVerticalInset)
                default:
                    EmptyView()
                }
            }
            .onPreferenceChange(ArticleListDetachedTopChromeHeightPreferenceKey.self) { height in
                guard abs(detachedTopChromeHeight - height) > 0.5 else { return }
                detachedTopChromeHeight = height
            }
            .toolbar {
                if capsulePlacement == .navigationTopLeading {
                    ToolbarItem(placement: .topBarLeading) {
                        ArticleListTitleCapsule(
                            title: title,
                            subtitle: capsuleSubtitle(landscapeSubtitle),
                            widthReservationSubtitle: capsuleSubtitle(landscapeWidthReservationSubtitle),
                            layout: .compactStacked,
                            action: onSelectScope,
                            usesSystemToolbarGlass: true
                        )
                    }
                }
            }
    }
}

extension ContentView {
    private var usesReaderInspector: Bool {
        adaptivePresentation.readerPresentationKind == .inspector
    }

    /// The browser, reader and share sheets follow whichever surface is
    /// frontmost. A view can present only one sheet, so exactly one side — the
    /// root or the search sheet — is active at a time.
    private func gatedBrowser(active: Bool) -> Binding<IOSBrowserURL?> {
        Binding(get: { active ? browser : nil }, set: { if active { browser = $0 } })
    }

    private func gatedShare(active: Bool) -> Binding<IOSSharePayload?> {
        Binding(get: { active ? sharePayload : nil }, set: { if active { sharePayload = $0 } })
    }

    private func gatedReaderSheet(active: Bool) -> Binding<IOSReaderArticle?> {
        Binding(
            get: { active && !usesReaderInspector ? readerArticle : nil },
            set: { if $0 == nil, active, !usesReaderInspector { dismissReader() } }
        )
    }


    private var readerInspectorBinding: Binding<Bool> {
        Binding(
            get: { usesReaderInspector && readerArticle != nil },
            set: { if !$0, usesReaderInspector { dismissReader() } }
        )
    }

    @ViewBuilder
    private func readerView(for article: ArticleSummary) -> some View {
        VStack(spacing: 0) {
            ReaderArticleHeader(article: article)
            Group {
                if readerIsLoading {
                    ProgressView("Loading article...")
                } else if let readerErrorMessage {
                    ContentUnavailableView("Unable to load article", systemImage: "exclamationmark.triangle", description: Text(readerErrorMessage))
                } else if let readerDocument {
                    ScrollView { ReaderDocumentContent(document: readerDocument, openOriginal: { openOriginal(article) }) }
                } else {
                    ContentUnavailableView("No article selected", systemImage: "doc.text")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.openURL, OpenURLAction { url in
            UIApplication.shared.open(url, options: [:])
            return .handled
        })
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(IOSReaderDismissalPresentation.title, action: dismissReader)
            }
        }
    }

    private func dismissReader() {
        readerArticle = nil
        readerGeneration += 1
    }

    private func openOriginal(_ article: ArticleSummary) {
        guard let url = ArticleOpenRoutingPolicy.validWebURL(article.url) else {
            readerErrorMessage = String(localized: "The article does not have a valid web URL.")
            return
        }
        UIApplication.shared.open(url, options: [:])
    }
}

private struct IOSInAppBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private struct IOSShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
