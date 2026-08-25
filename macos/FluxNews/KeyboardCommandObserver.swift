import AppKit
import SwiftUI

enum ArticleKeyboardCommand { case moveUp, moveDown, open, toggleRead, toggleStarred, refresh, dismiss }
struct KeyboardCommandObserver: NSViewRepresentable {
    let onCommand: (ArticleKeyboardCommand) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCommand: onCommand) }
    func makeNSView(context: Context) -> NSView { let view = NSView(); context.coordinator.view = view; context.coordinator.start(); return view }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.view = view; context.coordinator.onCommand = onCommand }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
    final class Coordinator {
        weak var view: NSView?; var onCommand: (ArticleKeyboardCommand) -> Void; private var monitor: Any?
        init(onCommand: @escaping (ArticleKeyboardCommand) -> Void) { self.onCommand = onCommand }
        func start() { guard monitor == nil else { return }; monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in guard let self, event.window === self.view?.window, !(event.window?.firstResponder is NSTextView), let command = self.command(for: event) else { return event }; self.onCommand(command); return nil } }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        private func command(for event: NSEvent) -> ArticleKeyboardCommand? { let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift]); if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "r" { return .refresh }; guard modifiers.isEmpty else { return nil }; switch event.keyCode { case 126: return .moveUp; case 125: return .moveDown; case 36, 76: return .open; case 53: return .dismiss; default: switch event.charactersIgnoringModifiers?.lowercased() { case "m": return .toggleRead; case "s": return .toggleStarred; default: return nil } } }
    }
}
