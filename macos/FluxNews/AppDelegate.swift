import AppKit
import Combine
import CoreSpotlight
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let store = BrowserStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var countObservation: AnyCancellable?
    private var catalogObservation: AnyCancellable?
    private var shortcutObservation: AnyCancellable?
    private let spotlightIndexer = SpotlightIndexer()
    private lazy var shortcutRegistrar = GlobalShortcutRegistrar { [weak self] in self?.show() }
    private var sidebarVisible = false
    private var fallbackPanel: NSPanel?
    private lazy var readerWindow = ReaderWindowController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        SystemNotificationManager.shared.configure()
        SystemNotificationManager.shared.onFeedSelected = { [weak self] feedID in
            guard let self else { return }
            self.show()
            self.store.selectNotificationFeed(feedID)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: 72)
        if let button = statusItem.button {
            button.image = Bundle.main.url(forResource: "FluxNewsTemplate", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.toolTip = "FluxNews"
            button.setAccessibilityLabel("FluxNews")
            button.target = self
            button.action = #selector(togglePopover)
        }
        countObservation = store.$unreadTotal.combineLatest(store.$hasPendingNewData).sink { [weak self] unreadTotal, hasPendingNewData in
            guard let button = self?.statusItem.button else { return }
            button.title = StatusItemPresentation.title(unreadTotal: unreadTotal, hasPendingNewData: hasPendingNewData)
            button.setAccessibilityValue(StatusItemPresentation.accessibilityValue(unreadTotal: unreadTotal, hasPendingNewData: hasPendingNewData))
        }
        popover.behavior = .transient; popover.animates = true; popover.delegate = self; popover.contentSize = size(sidebarVisible: false); popover.contentViewController = host()
        AppRouter.shared.configure(open: { [weak self] route in self?.store.route(to: route); self?.show() }, refresh: { [weak self] in self?.show(); self?.store.sync(reason: .manual) })
        store.onOpenDetail = { [weak self] article in self?.readerWindow.show(article: article) }
        catalogObservation = store.$catalog.dropFirst().removeDuplicates().sink { [weak self] catalog in
            AppRouter.shared.updateCatalog(catalog)
            self?.spotlightIndexer.update(catalog)
            FluxNewsShortcuts.updateAppShortcutParameters()
        }
        shortcutObservation = store.$globalShortcut.sink { [weak self] shortcut in
            guard let self else { return }
            let status = shortcutRegistrar.register(shortcut)
            if status == noErr { store.globalShortcutRegistrationError = nil }
            else {
                NativeLog.shortcut.error("global shortcut registration failed status=\(status, privacy: .public)")
                store.globalShortcutRegistrationError = "The selected global shortcut is unavailable. Choose another shortcut."
            }
        }
        store.start()
    }
    func applicationDidBecomeActive(_ notification: Notification) { store.resume() }
    @objc private func togglePopover() { if popover.isShown || fallbackPanel?.isVisible == true { dismiss() } else { show() } }
    func popoverWillShow(_ notification: Notification) { store.popoverVisible = true; popover.contentSize = size(sidebarVisible: sidebarVisible) }
    func popoverDidClose(_ notification: Notification) { store.popoverVisible = false; store.syncIfStale() }
    func windowWillClose(_ notification: Notification) { guard notification.object as? NSPanel === fallbackPanel else { return }; store.popoverVisible = false; store.syncIfStale() }
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let route = SpotlightIndexer.route(from: identifier) else { return false }
        AppRouter.shared.open(route)
        return true
    }
    private func host() -> NSHostingController<PopoverContentView> { NSHostingController(rootView: PopoverContentView(store: store, layoutChanged: { [weak self] visible in self?.resize(sidebarVisible: visible) }, dismiss: { [weak self] in self?.dismiss() })) }
    private func show() { NSApplication.shared.activate(ignoringOtherApps: true); if let button = usableButton() { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); popover.contentViewController?.view.window?.makeKey() } else { showFallback() } }
    private func usableButton() -> NSStatusBarButton? { guard let button = statusItem.button, let window = button.window, let screen = window.screen else { return nil }; return screen.frame.intersects(window.convertToScreen(button.convert(button.bounds, to: nil))) ? button : nil }
    private func dismiss() { if popover.isShown { popover.performClose(nil) }; fallbackPanel?.close() }
    private func showFallback() { let panel = fallbackPanel ?? makeFallback(); fallbackPanel = panel; panel.setContentSize(size(sidebarVisible: sidebarVisible)); store.popoverVisible = true; panel.center(); panel.makeKeyAndOrderFront(nil) }
    private func makeFallback() -> NSPanel { let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size(sidebarVisible: sidebarVisible)), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false); panel.title = "FluxNews"; panel.isFloatingPanel = true; panel.level = .floating; panel.collectionBehavior = [.moveToActiveSpace, .transient]; panel.isReleasedWhenClosed = false; panel.delegate = self; panel.contentViewController = host(); return panel }
    private func resize(sidebarVisible: Bool) { self.sidebarVisible = sidebarVisible; let newSize = size(sidebarVisible: sidebarVisible); guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { popover.contentSize = newSize; fallbackPanel?.setContentSize(newSize); return }; if popover.isShown { NSAnimationContext.runAnimationGroup { $0.duration = PopoverLayout.animation; $0.allowsImplicitAnimation = true; popover.contentSize = newSize } } else { fallbackPanel?.setContentSize(newSize) } }
    private func size(sidebarVisible: Bool) -> NSSize {
        let visibleHeight = statusItem.button?.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? PopoverLayout.rowHeight + PopoverLayout.verticalScreenMargin
        return NSSize(
            width: PopoverLayout.width(style: store.articleListStyle, sidebarVisible: sidebarVisible),
            height: min(store.articleListStyle == .row ? PopoverLayout.rowHeight : PopoverLayout.cardHeight, max(320, visibleHeight - PopoverLayout.verticalScreenMargin))
        )
    }
}
