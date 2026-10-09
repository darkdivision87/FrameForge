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
