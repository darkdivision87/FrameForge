// Draws the app icon: the editor header's mint stack mark on a dark rounded square.
// Run via scripts/make-icon.sh, which turns the PNGs into Resources/AppIcon.icns.
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    // Apple's macOS icon grid: an 824-point body centred in a 1024 canvas.
    let body = CGRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185*s, yRadius: 185*s)
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.22, alpha: 1), ending: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1))!.draw(in: shape, angle: -90)
    // The editor header's mark (SF Symbol square.stack.3d.up.fill, mint), centred.
    let config = NSImage.SymbolConfiguration(pointSize: 440*s, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [.systemMint]))
    let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let fit = min(500*s/symbol.size.width, 500*s/symbol.size.height)
    let size = CGSize(width: symbol.size.width*fit, height: symbol.size.height*fit)
    symbol.draw(in: CGRect(x: body.midX-size.width/2, y: body.midY-size.height/2, width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: out.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points*2).write(to: out.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
