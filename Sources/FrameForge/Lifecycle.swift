import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = store else { return .terminateNow }
        if store.recording {
            Task { await store.stopRecording(); sender.reply(toApplicationShouldTerminate:store.error == nil) }
            return .terminateLater
        }
        if store.busy { store.error = "Wait for the current operation or cancel the export before quitting."; return .terminateCancel }
        return .terminateNow
    }
}

/// Keep the editor out of capture without hiding the menu-bar stop control.
@MainActor final class CaptureWindowVisibility {
    private var windows: [NSWindow] = []
    private weak var keyWindow: NSWindow?
    func hide() {
        guard windows.isEmpty else { return }
        keyWindow = NSApp.keyWindow
        windows = NSApp.windows.filter { ($0.isVisible || $0.canBecomeMain) && $0.level == .normal }
        windows.forEach { $0.orderOut(nil) }
    }
    func restore() {
        let saved = windows; windows = []
        NSApp.unhide(nil)
        saved.forEach { $0.deminiaturize(nil); $0.orderFront(nil) }
        (keyWindow ?? saved.first)?.makeKeyAndOrderFront(nil)
        keyWindow = nil
        NSApp.activate(ignoringOtherApps: true)
    }
}
