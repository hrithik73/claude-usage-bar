import AppKit
// Renders the app icon: warm gradient squircle with the same two rings as the menu bar icon.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824) // Apple grid: ~10% margin
    NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    NSGradient(starting: NSColor(red: 0.93, green: 0.55, blue: 0.40, alpha: 1), ending: NSColor(red: 0.74, green: 0.33, blue: 0.22, alpha: 1))!.draw(in: shape, angle: -90)
    let c = NSPoint(x: 512, y: 512)
    for (pct, radius) in [(0.72, 280.0), (0.45, 160.0)] {
        let track = NSBezierPath(); track.lineWidth = 78
        track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        NSColor.white.withAlphaComponent(0.25).setStroke(); track.stroke()
        let arc = NSBezierPath(); arc.lineWidth = 78; arc.lineCapStyle = .round
        arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * pct, clockwise: true)
        NSColor.white.setStroke(); arc.stroke()
    }
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
