import AppKit

extension NSScreen {
    var displayID: UInt32? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}

/// What the person picked: a display, plus a top-left unit region on it (nil = the entire display).
struct CaptureTarget: Equatable { let displayID: UInt32; let region: CGRect? }

@MainActor final class RegionSelector {
    private var windows: [SelectionWindow] = []
    private var views: [SelectionView] = []
    private var completion: ((CaptureTarget?) -> Void)?
    /// Covers each listed display. Dragging draws a region that can then be moved and resized;
    /// the control bar's confirm button (or Return) accepts it. With `allowsFullScreen`, clicking a
    /// display with no region drawn selects that whole display. Escape cancels.
    /// Uses non-activating panels so the app being recorded stays frontmost.
    func select(displayIDs: [UInt32], allowsFullScreen: Bool) async throws -> CaptureTarget? {
        guard completion == nil else { throw ForgeError.message("A region selection is already open.") }
        let screens = NSScreen.screens.filter { $0.displayID.map(displayIDs.contains) ?? false }
        guard !screens.isEmpty else { throw ForgeError.message("Display disconnected. Refresh sources and select it again.") }
        return await withCheckedContinuation { continuation in
            completion = { continuation.resume(returning: $0) }
            let pointer = NSEvent.mouseLocation
            for screen in screens {
                guard let id = screen.displayID else { continue }
                let overlay = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                overlay.setFrame(screen.frame, display: true)
                overlay.title = "Select Recording Area"
                overlay.level = .screenSaver
                overlay.isOpaque = false; overlay.backgroundColor = .clear
                overlay.hasShadow = false; overlay.isReleasedWhenClosed = false
                // Explicitly false: by default macOS sends clicks on fully transparent pixels (the
                // undimmed region) to the app underneath, which made the region impossible to move.
                overlay.ignoresMouseEvents = false
                overlay.hidesOnDeactivate = false; overlay.becomesKeyOnlyIfNeeded = false
                overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), allowsFullScreen: allowsFullScreen)
                view.hovered = screen.frame.contains(pointer)
                view.finish = { [weak self] rect in
                    guard let rect = rect else { self?.finish(CaptureTarget(displayID: id, region: nil)); return }
                    self?.finish((try? CaptureGeometry.normalized(rect, in: screen.frame.size)).map { CaptureTarget(displayID: id, region: $0) })
                }
                view.cancel = { [weak self] in self?.finish(nil) }
                // One region at a time: starting one on this display clears any on the others.
                view.beganSelection = { [weak self, weak view] in self?.views.filter { $0 !== view }.forEach { $0.clearSelection() } }
                overlay.cancel = view.cancel
                overlay.contentView = view
                overlay.orderFrontRegardless()
                windows.append(overlay); views.append(view)
            }
            let key = windows.first { $0.frame.contains(pointer) } ?? windows[0]
            key.makeKey(); key.makeFirstResponder(key.contentView)
        }
    }
    private func finish(_ target: CaptureTarget?) {
        guard let done = completion else { return }
        completion = nil
        for window in windows { window.orderOut(nil); window.close() }
        windows = []; views = []
        NSCursor.arrow.set()
        done(target)
    }
}
private final class SelectionWindow: NSPanel {
    var cancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { cancel?() }
}
/// Sides of the selection being dragged, in the view's flipped (top-left) coordinates.
private struct Edges: OptionSet {
    let rawValue: Int
    static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
}
private final class SelectionView: NSView {
    /// nil = the entire display.
    var finish: ((CGRect?) -> Void)?
    var cancel: (() -> Void)?
    var beganSelection: (() -> Void)?
    var hovered = false { didSet { needsDisplay = true } }
    private enum Drag { case create(CGPoint, hadSelection: Bool), move(CGRect, CGPoint), resize(CGRect, CGPoint, Edges) }
    private static let minimumSide: CGFloat = 16
    private static let handleSlop: CGFloat = 8
    private let allowsFullScreen: Bool
    private let controls: SelectionControls
    /// Shown while no region is drawn: instructions plus a Cancel button, so there is always a visible way out.
    private let hintBar: SelectionControls
    private var drag: Drag?
    private var selection: CGRect? { didSet { layoutControls(); needsDisplay = true } }
    init(frame: CGRect, allowsFullScreen: Bool) {
        self.allowsFullScreen = allowsFullScreen
        controls = SelectionControls(confirmTitle: allowsFullScreen ? "Record" : "Select Region", recording: allowsFullScreen)
        hintBar = SelectionControls(confirmTitle: nil, recording: false)
        super.init(frame: frame)
        hintBar.setText(allowsFullScreen ? "Drag to frame a region · Click to record this screen · Esc to cancel" : "Drag the area to record · Esc to cancel")
        controls.isHidden = true
        controls.confirm = { [weak self] in self?.confirm() }
        for bar in [controls, hintBar] { bar.cancel = { [weak self] in self?.cancel?() }; addSubview(bar) }
        layoutControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func clearSelection() { drag = nil; selection = nil }
    private func confirm() { if let rect = selection { finish?(rect) } }

    // MARK: Pointer
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // activeAlways: the overlay works while another app stays frontmost.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        window?.makeKey(); window?.makeFirstResponder(self)
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { hovered = false }
    private func updateCursor(at point: CGPoint) {
        guard drag == nil else { return }
        if [controls, hintBar].contains(where: { !$0.isHidden && $0.frame.contains(point) }) { NSCursor.arrow.set(); return }
        guard let rect = selection else { NSCursor.crosshair.set(); return }
        let edges = self.edges(at: point, of: rect)
        if edges == [.left] || edges == [.right] { NSCursor.resizeLeftRight.set() }
        else if edges == [.top] || edges == [.bottom] { NSCursor.resizeUpDown.set() }
        else if !edges.isEmpty { NSCursor.crosshair.set() }
        else if rect.contains(point) { NSCursor.openHand.set() }
        else { NSCursor.crosshair.set() }
    }
    private func edges(at point: CGPoint, of rect: CGRect) -> Edges {
        let slop = Self.handleSlop
        guard rect.insetBy(dx: -slop, dy: -slop).contains(point) else { return [] }
        var edges: Edges = []
        if abs(point.x-rect.minX) <= slop { edges.insert(.left) } else if abs(point.x-rect.maxX) <= slop { edges.insert(.right) }
        if abs(point.y-rect.minY) <= slop { edges.insert(.top) } else if abs(point.y-rect.maxY) <= slop { edges.insert(.bottom) }
        return edges
    }

    // MARK: Keyboard
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel?()
        case 36, 76:
            if selection != nil { confirm() } else if allowsFullScreen { finish?(nil) }
        default: super.keyDown(with: event)
        }
    }

    // MARK: Drawing a region, moving it, resizing it
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let rect = selection {
            if event.clickCount == 2 && rect.contains(point) { confirm(); return }
            let edges = self.edges(at: point, of: rect)
            if !edges.isEmpty { drag = .resize(rect, point, edges); return }
            if rect.contains(point) { drag = .move(rect, point); NSCursor.closedHand.set(); return }
        }
        drag = .create(point, hadSelection: selection != nil)
        selection = nil
        beganSelection?()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .create(let anchor, _):
            selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x-anchor.x), height: abs(point.y-anchor.y)).intersection(bounds)
        case .move(let start, let origin):
            let x = min(max(start.minX + point.x-origin.x, bounds.minX), bounds.maxX-start.width)
            let y = min(max(start.minY + point.y-origin.y, bounds.minY), bounds.maxY-start.height)
            selection = CGRect(x: x, y: y, width: start.width, height: start.height)
        case .resize(let start, let origin, let edges):
            var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
            let dx = point.x-origin.x, dy = point.y-origin.y
            if edges.contains(.left) { minX += dx }
            if edges.contains(.right) { maxX += dx }
            if edges.contains(.top) { minY += dy }
            if edges.contains(.bottom) { maxY += dy }
            // Dragging an edge past its opposite side flips the region rather than collapsing it.
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX-minX), height: abs(maxY-minY)).intersection(bounds)
        case nil: return
        }
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let tooSmall = selection.map { $0.width < Self.minimumSide || $0.height < Self.minimumSide } ?? true
        switch drag {
        case .create(let anchor, let hadSelection):
            if tooSmall {
                selection = nil
                // A plain click records the whole display, unless it only dismissed a region.
                if allowsFullScreen && !hadSelection && hypot(point.x-anchor.x, point.y-anchor.y) < 4 { drag = nil; finish?(nil); return }
            }
        case .move(let start, _), .resize(let start, _, _):
            if tooSmall { selection = start }
        case nil: break
        }
        drag = nil
        layoutControls()
        updateCursor(at: point)
    }

    // MARK: Layout and drawing
    private func layoutControls() {
        hintBar.isHidden = selection != nil
        if !hintBar.isHidden {
            let size = hintBar.fittingSize
            hintBar.frame = CGRect(x: bounds.midX-size.width/2, y: 64, width: size.width, height: size.height)
        }
        guard let rect = selection, rect.width >= Self.minimumSide, rect.height >= Self.minimumSide else { controls.isHidden = true; return }
        controls.setText("\(Int(rect.width)) × \(Int(rect.height))")
        let size = controls.fittingSize, gap: CGFloat = 12, margin: CGFloat = 8
        let x = min(max(rect.midX-size.width/2, margin), bounds.width-size.width-margin)
        var y = rect.maxY + gap
        if y + size.height > bounds.height-margin { y = rect.minY - gap - size.height }
        if y < margin { y = rect.maxY - gap - size.height }
        controls.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        controls.isHidden = false
    }
    override func draw(_ dirtyRect: NSRect) {
        let offersFullScreen = allowsFullScreen && hovered && selection == nil && drag == nil
        NSColor.black.withAlphaComponent(offersFullScreen ? 0.2 : 0.45).setFill()
        let shade = NSBezierPath(rect: bounds)
        if let rect = selection { shade.appendRect(rect); shade.windingRule = .evenOdd }
        shade.fill()
        NSColor.systemMint.setStroke()
        if let rect = selection {
            let outline = NSBezierPath(rect: rect); outline.lineWidth = 2; outline.stroke()
            for x in [rect.minX, rect.midX, rect.maxX] {
                for y in [rect.minY, rect.midY, rect.maxY] where !(x == rect.midX && y == rect.midY) {
                    let handle = NSBezierPath(ovalIn: CGRect(x: x-5, y: y-5, width: 10, height: 10))
                    NSColor.white.setFill(); handle.fill(); handle.lineWidth = 1.5; handle.stroke()
                }
            }
            return
        }
        if offersFullScreen {
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)); outline.lineWidth = 6; outline.stroke()
        }
    }
}
/// Floating bar: a label, Cancel, and (when `confirmTitle` is set) the confirm (Record) button.
private final class SelectionControls: NSView {
    var confirm: (() -> Void)?
    var cancel: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    init(confirmTitle: String?, recording: Bool) {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer?.cornerRadius = 10
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        var views: [NSView] = [label, cancelButton]
        if let confirmTitle = confirmTitle {
            let confirmButton = NSButton(title: confirmTitle, target: self, action: #selector(confirmPressed))
            confirmButton.keyEquivalent = "\r"
            if recording {
                confirmButton.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
                confirmButton.imagePosition = .imageLeading
                confirmButton.bezelColor = .systemRed
            }
            views.append(confirmButton)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setText(_ text: String) { label.stringValue = text }
    // Clicks on the bar's padding must not start a new region underneath it.
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func confirmPressed() { confirm?() }
    @objc private func cancelPressed() { cancel?() }
}
