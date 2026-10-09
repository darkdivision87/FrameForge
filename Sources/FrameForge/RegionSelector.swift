import AppKit

@MainActor final class RegionSelector {
    private var window: SelectionWindow?
    private var completion: ((CGRect?) -> Void)?
    private weak var previousWindow: NSWindow?
    func select(displayID: UInt32) async throws -> CGRect? {
        guard window == nil else { throw ForgeError.message("A region selection is already open.") }
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }) else { throw ForgeError.message("Display disconnected. Refresh sources and select it again.") }
        return await withCheckedContinuation { continuation in
            previousWindow = NSApp.keyWindow
            let overlay = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            overlay.setFrame(screen.frame, display: true)
            overlay.title = "Select Recording Region"
            overlay.level = .screenSaver
            overlay.isOpaque = false; overlay.backgroundColor = .clear
            overlay.hasShadow = false; overlay.isReleasedWhenClosed = false
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero,size: screen.frame.size))
            completion = { rect in
                continuation.resume(returning: rect.flatMap { try? CaptureGeometry.normalized($0, in: screen.frame.size) })
            }
            view.finish = { [weak self] rect in self?.finish(rect) }
            overlay.cancel = { [weak self] in self?.finish(nil) }
            overlay.contentView = view; overlay.makeKeyAndOrderFront(nil); overlay.makeMain(); overlay.makeFirstResponder(view)
            window = overlay
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private func finish(_ rect: CGRect?) {
        guard let done = completion else { return }
        completion = nil
        window?.orderOut(nil); window?.close(); window = nil
        previousWindow?.makeKeyAndOrderFront(nil)
        done(rect)
    }
}
private final class SelectionWindow: NSWindow {
    var cancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { cancel?() }
}
private final class SelectionView: NSView {
    var finish: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var selection: CGRect?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { finish?(nil) } }
    override func mouseDown(with event: NSEvent) { anchor = convert(event.locationInWindow, from:nil); selection = nil; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor = anchor else { return }
        let point = convert(event.locationInWindow,from:nil)
        selection = CGRect(x:min(anchor.x,point.x),y:min(anchor.y,point.y),width:abs(point.x-anchor.x),height:abs(point.y-anchor.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with:event)
        if let rect = selection, rect.width >= 16, rect.height >= 16 { finish?(rect) }
        else { anchor = nil; selection = nil; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        let shade = NSBezierPath(rect:bounds)
        if let rect = selection { shade.appendRect(rect); shade.windingRule = .evenOdd }
        shade.fill()
        if let rect = selection {
            NSColor.systemMint.setStroke(); let outline = NSBezierPath(rect:rect); outline.lineWidth = 2; outline.stroke()
        }
        let text = selection.map { "\(Int($0.width)) × \(Int($0.height)) points · Release to select · Esc to cancel" } ?? "Drag the area to record · Esc to cancel"
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:18,weight:.semibold),.foregroundColor:NSColor.white]
        (text as NSString).draw(at:CGPoint(x:32,y:32),withAttributes:attributes)
    }
}
