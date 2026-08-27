import AppKit
import SwiftUI

@MainActor
final class ReaderWindowController: NSObject, ObservableObject {
    @Published fileprivate var article: ArticleSummary?
    @Published fileprivate var document: ReaderDocument?
    @Published fileprivate var isLoading = false
    @Published fileprivate var errorMessage: String?

    private weak var store: BrowserStore?
    private var window: NSWindow?
    private var requests = ReaderRequestState()
    private var sharingPicker: NSSharingServicePicker?
    private weak var starButton: NSButton?

    init(store: BrowserStore) { self.store = store }

    func show(article: ArticleSummary) {
        let requestID = requests.begin()
        self.article = article
        document = nil
        errorMessage = nil
        isLoading = true
        makeWindowIfNeeded()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
        store?.setStarred(article, !article.isStarred)
        self.article = ArticleSummary(id: article.id, feedId: article.feedId, categoryId: article.categoryId, feedTitle: article.feedTitle, title: article.title, url: article.url, commentsUrl: article.commentsUrl, publishedAt: article.publishedAt, isRead: true, isStarred: !article.isStarred, preview: article.preview, imageUrl: article.imageUrl)
        updateStarButton()
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

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Reader"
        if !window.setFrameAutosaveName("FluxNews.Reader") { window.center() }
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "FluxNews.Reader.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.contentViewController = NSHostingController(rootView: ReaderWindowView(controller: self))
        self.window = window
    }

    private func updateStarButton() {
        guard let button = starButton else { return }
        button.image = NSImage(systemSymbolName: article?.isStarred == true ? "star.fill" : "star", accessibilityDescription: article?.isStarred == true ? "Unstar" : "Star")
        button.toolTip = article?.isStarred == true ? "Unstar" : "Star"
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
            item.label = "Star"
            let button = button(symbol: article?.isStarred == true ? "star.fill" : "star", label: article?.isStarred == true ? "Unstar" : "Star", action: #selector(toggleStarredFromToolbar))
            starButton = button
            item.view = button
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
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
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

private struct ReaderWindowView: View {
    @ObservedObject var controller: ReaderWindowController

    var body: some View {
        VStack(spacing: 0) {
            if let article = controller.article { ReaderHeader(article: article); Divider() }
            Group {
                if controller.isLoading { ProgressView("Loading article...") }
                else if let error = controller.errorMessage { ContentUnavailableView("Unable to load article", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else if let document = controller.document { ReaderDocumentView(document: document, openOriginal: controller.openOriginal) }
                else { ContentUnavailableView("No article selected", systemImage: "doc.text") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }.padding(20)
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
