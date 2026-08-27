import AppKit
import Combine
import SwiftUI

@MainActor
final class ReaderWindowController: NSObject, ObservableObject {
    @Published fileprivate var article: ArticleSummary?
    @Published fileprivate var document: ReaderDocument?
    @Published fileprivate var isLoading = false
    @Published fileprivate var errorMessage: String?

    private weak var store: BrowserStore?
    private var panel: NSPanel?
    private var requests = ReaderRequestState()
    private var sharingPicker: NSSharingServicePicker?
    private var articlesObservation: AnyCancellable?

    init(store: BrowserStore) {
        self.store = store
        super.init()
        articlesObservation = store.$articles.sink { [weak self] articles in self?.synchronizeArticleState(from: articles) }
    }

    func show(article: ArticleSummary, togglesPreview: Bool, preferredScreen: NSScreen?) {
        makePanelIfNeeded()
        guard let panel else { return }
        switch ReaderPreviewAction.resolve(isVisible: panel.isVisible, currentArticleID: self.article?.id, requestedArticleID: article.id, togglesSameArticle: togglesPreview) {
        case .hide:
            panel.orderOut(nil)
            return
        case .show:
            position(panel, on: preferredScreen ?? currentScreen())
        case .replace:
            break
        }
        let requestID = requests.begin()
        self.article = article
        document = nil
        errorMessage = nil
        isLoading = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        store?.setRead(article, true)
        store?.loadReaderDocument(article) { [weak self] result in
            guard let self, self.requests.isCurrent(requestID) else { return }
            self.isLoading = false
            switch result {
            case let .success(document): self.document = document
            case let .failure(error): self.errorMessage = error.localizedDescription
            }
        }
    }

    func openOriginal() {
        guard let url = article.flatMap({ URL(string: $0.url) }) else { return }
        NSWorkspace.shared.open(url)
    }

    func toggleStarred() {
        guard let article else { return }
        store?.setStarred(article, !article.isStarred) { [weak self] accepted in
            guard accepted, let self, self.article?.id == article.id else { return }
            self.article = ArticleSummary(id: article.id, feedId: article.feedId, categoryId: article.categoryId, feedTitle: article.feedTitle, title: article.title, url: article.url, commentsUrl: article.commentsUrl, publishedAt: article.publishedAt, isRead: article.isRead, isStarred: !article.isStarred, preview: article.preview, imageUrl: article.imageUrl)
            self.updateStarToolbarItem()
        }
    }

    @objc private func toggleStarredFromToolbar() { toggleStarred() }
    @objc private func shareFromToolbar(_ sender: NSButton) {
        guard let article, let url = URL(string: article.url) else { return }
        let picker = NSSharingServicePicker(items: [article.title, url])
        sharingPicker = picker
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    @objc private func openFromToolbar() { guard let article else { return }; store?.open(article) }
    @objc private func showMoreMenu(_ sender: NSButton) { moreMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender) }
    @objc private func markUnread() { guard let article else { return }; store?.setRead(article, false) }
    @objc private func openInMiniflux() { guard let article else { return }; store?.openInMiniflux(article) }
    @objc private func openComments() { guard let article else { return }; store?.openComments(article) }
    @objc private func copyLink() { guard let article else { return }; store?.copyLink(article) }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame FluxNews.Reader")
        let panel = ReaderPreviewPanel(contentRect: NSRect(origin: .zero, size: ReaderPreviewGeometry.persistedSize()), styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .hudWindow], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.title = "Detail Preview"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: "FluxNews.Reader.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        panel.toolbar = toolbar
        panel.toolbarStyle = .unifiedCompact
        panel.titleVisibility = .hidden
        panel.contentViewController = ReaderVisualEffectViewController(rootView: ReaderWindowView(controller: self))
        self.panel = panel
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        let size = ReaderPreviewGeometry.persistedSize()
        panel.setContentSize(size)
        let visibleFrame = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        panel.setFrameOrigin(ReaderPreviewGeometry.centeredFrame(size: panel.frame.size, visibleFrame: visibleFrame).origin)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func starImage(starred: Bool) -> NSImage? {
        let base = NSImage(
            systemSymbolName: starred ? "star.fill" : "star",
            accessibilityDescription: starred ? "Unstar" : "Star"
        )

        return base?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: 16,
                weight: .regular
            )
        )
    }

    private func updateStarToolbarItem() {

        guard let item = panel?.toolbar?.items.first(where: { $0.itemIdentifier == .star }) else { return }
        let starred = article?.isStarred == true
        item.image = starImage(starred: starred)
        item.label = starred ? "Unstar" : "Star"
        item.paletteLabel = item.label
        item.toolTip = item.label
    }

    private func currentScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
    }

    private func synchronizeArticleState(from visibleArticles: [ArticleSummary]) {
        guard let article,
              let starred = ReaderArticleState.starredState(articleID: article.id, visibleArticles: visibleArticles.map { ($0.id, $0.isStarred) }),
              starred != article.isStarred else { return }
        self.article = ArticleSummary(id: article.id, feedId: article.feedId, categoryId: article.categoryId, feedTitle: article.feedTitle, title: article.title, url: article.url, commentsUrl: article.commentsUrl, publishedAt: article.publishedAt, isRead: article.isRead, isStarred: starred, preview: article.preview, imageUrl: article.imageUrl)
        updateStarToolbarItem()
    }
}

private final class ReaderPreviewPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

private final class ReaderVisualEffectViewController: NSViewController {
    private let rootView: ReaderWindowView

    init(rootView: ReaderWindowView) { self.rootView = rootView; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        let host = NSHostingController(rootView: rootView)
        addChild(host)
        host.view.frame = effect.bounds
        host.view.autoresizingMask = [.width, .height]
        effect.addSubview(host.view)
        view = effect
    }
}

extension NSToolbarItem.Identifier {
    static let star = Self("FluxNews.Reader.Star")
    static let share = Self("FluxNews.Reader.Share")
    static let open = Self("FluxNews.Reader.Open")
    static let more = Self("FluxNews.Reader.More")
}

extension ReaderWindowController: NSToolbarDelegate {
    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.star, .share, .open, .more, .flexibleSpace] }
    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .star, .share, .open, .more] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .star:
            let starred = article?.isStarred == true
            item.label = starred ? "Unstar" : "Star"
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = starImage(starred: starred)
            item.target = self
            item.action = #selector(toggleStarredFromToolbar)
        case .share:
            item.label = "Share"
            item.view = button(symbol: "square.and.arrow.up", label: "Share", action: #selector(shareFromToolbar(_:)))
        case .open:
            item.label = "Open"
            item.view = button(symbol: "arrow.up.forward.app", label: "Open", action: #selector(openFromToolbar))
        case .more:
            item.label = "More"
            item.view = button(symbol: "ellipsis", label: "More", action: #selector(showMoreMenu(_:)))
        default: return nil
        }
        return item
    }

    private func button(symbol: String, label: String, action: Selector?) -> NSButton {
      let baseImage = NSImage(
          systemSymbolName: symbol,
          accessibilityDescription: label
      )!

      let image = baseImage.withSymbolConfiguration(
          NSImage.SymbolConfiguration(
              pointSize: 16,
              weight: .regular
          )
      ) ?? baseImage
      let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Mark as Unread", action: #selector(markUnread), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Original", action: #selector(openFromToolbar), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open in Miniflux", action: #selector(openInMiniflux), keyEquivalent: "").target = self
        if article?.commentsUrl.isEmpty == false { menu.addItem(withTitle: "Open Comments", action: #selector(openComments), keyEquivalent: "").target = self }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Link", action: #selector(copyLink), keyEquivalent: "").target = self
        return menu
    }
}

extension ReaderWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, panel.isVisible, let contentView = panel.contentView else { return }
        ReaderPreviewGeometry.persist(size: contentView.bounds.size)
    }
}

private struct ReaderWindowView: View {
    @ObservedObject var controller: ReaderWindowController

    var body: some View {
        VStack(spacing: 0) {
            if let article = controller.article { ReaderHeader(article: article) }
            Group {
                if controller.isLoading { ProgressView("Loading article...") }
                else if let error = controller.errorMessage { ContentUnavailableView("Unable to load article", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else if let document = controller.document { ReaderDocumentView(document: document, openOriginal: controller.openOriginal) }
                else { ContentUnavailableView("No article selected", systemImage: "doc.text") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            KeyboardCommandObserver { command in
                if command == .openDetail || command == .dismiss { controller.hide() }
            }
        }
        .environment(\.openURL, OpenURLAction { url in NSWorkspace.shared.open(url); return .handled })
    }
}

private struct ReaderHeader: View {
    private static let dateFormatter = ISO8601DateFormatter()
    let article: ArticleSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(article.feedTitle).font(.subheadline).foregroundStyle(.secondary)
            Text(article.title).font(.title2.bold()).textSelection(.enabled)
            if let date = Self.dateFormatter.date(from: article.publishedAt) { Text(date.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ReaderDocumentView: View {
    let document: ReaderDocument
    let openOriginal: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ReaderBlocksView(blocks: document.blocks)
                if document.hasSimplifiedContent || document.wasTruncated {
                    HStack(spacing: 4) { Text(readerNotice); Text("·").foregroundStyle(.tertiary); Button("Open Original", action: openOriginal).buttonStyle(.link) }
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }
            }.frame(maxWidth: 680, alignment: .leading).padding(24).frame(maxWidth: .infinity, alignment: .center)
        }.textSelection(.enabled)
    }
    private var readerNotice: String {
        switch (document.hasSimplifiedContent, document.wasTruncated) {
        case (true, true): "Some content was simplified and truncated"
        case (true, false): "Some content was simplified"
        case (false, true): "Some content was truncated"
        case (false, false): ""
        }
    }
}

private struct ReaderBlocksView: View {
    let blocks: [ReaderBlock]
    var body: some View { ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) } }

    @ViewBuilder private func blockView(_ block: ReaderBlock) -> some View {
        switch block {
        case let .paragraph(inlines): Text(readerText(inlines)).font(.body).fixedSize(horizontal: false, vertical: true)
        case let .heading(level, inlines): Text(readerText(inlines)).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline).fixedSize(horizontal: false, vertical: true)
        case let .image(url, alt, link): ReaderImage(url: url, alt: alt, link: link)
        case let .list(ordered, items):
            VStack(alignment: .leading, spacing: 8) { ForEach(Array(items.enumerated()), id: \.offset) { index, item in HStack(alignment: .top, spacing: 8) { Text(ordered ? "\(index + 1)." : "•").foregroundStyle(.secondary); ReaderBlocksView(blocks: item.blocks) } } }.padding(.leading, 12)
        case let .quote(blocks): ReaderBlocksView(blocks: blocks).padding(.leading, 16).overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.45)).frame(width: 3) }.foregroundStyle(.secondary)
        case let .codeBlock(text): Text(text).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .horizontalRule: Divider().padding(.vertical, 4)
        case let .externalContent(url, label): if let url = URL(string: url) { Link(label ?? url.absoluteString, destination: url).lineLimit(2) }
        }
    }

    private func readerText(_ inlines: [ReaderInline]) -> AttributedString {
        inlines.reduce(into: AttributedString()) { result, inline in
            switch inline {
            case let .text(text): result += AttributedString(text)
            case let .bold(inlines): var text = readerText(inlines); text.inlinePresentationIntent = .stronglyEmphasized; result += text
            case let .italic(inlines): var text = readerText(inlines); text.inlinePresentationIntent = .emphasized; result += text
            case let .code(text): var text = AttributedString(text); text.font = .system(.body, design: .monospaced); result += text
            case let .link(url, inlines): var text = readerText(inlines); text.link = URL(string: url); result += text
            }
        }
    }
}

private struct ReaderImage: View {
    let url: String
    let alt: String?
    let link: String?
    var body: some View {
        Group {
            if let link, let destination = URL(string: link) {
                Link(destination: destination) { imageContent }
            } else {
                imageContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(alt ?? "Article image")
    }
    @ViewBuilder private var imageContent: some View {
        if let imageURL = URL(string: url) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFit()
                case .failure: fallback
                default: ProgressView().frame(height: 120)
                }
            }
        } else { fallback }
    }
    @ViewBuilder private var fallback: some View {
        if let link, let destination = URL(string: link) { Link(alt?.isEmpty == false ? alt! : "Open image", destination: destination).padding(12).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6)) }
    }
}
