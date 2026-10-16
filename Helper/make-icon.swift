// Draws the app icon: a dark matte tile with the black island hanging from the top edge, showing a
// now-playing waveform and a green "done" dot. Run by `./install.sh icon`; writes Resources/AppIcon.icns.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor(white: 0.12, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// Matte gradient and a faint top sheen.
NSGradient(starting: NSColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1),
           ending: NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))!.draw(in: shape, angle: -90)
NSColor.white.withAlphaComponent(0.08).setStroke()
shape.lineWidth = 4
shape.stroke()

// The island: a black pill under the top edge.
shape.addClip()
let island = NSRect(x: 212, y: 600, width: 600, height: 196)
NSColor.black.setFill()
// Flat against the top edge with rounded lower corners, like the notch it grows out of.
NSBezierPath(roundedRect: island, xRadius: 98, yRadius: 98).fill()
NSBezierPath(rect: NSRect(x: island.minX, y: island.midY, width: island.width, height: tile.maxY - island.midY)).fill()

// Waveform on the left of the island.
let bars: [CGFloat] = [0.45, 0.85, 0.6, 1.0, 0.5]
for (i, h) in bars.enumerated() {
    let bh = 96 * h
    let r = NSRect(x: island.minX + 92 + CGFloat(i) * 34, y: island.midY - bh / 2, width: 18, height: bh)
    NSColor(red: 0.98, green: 0.62, blue: 0.27, alpha: 1).setFill()
    NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
}
// Green dot on the right.
NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: island.maxX - 92 - 56, y: island.midY - 28, width: 56, height: 56)).fill()

// Widget tiles below: the island opened up.
for (i, r) in [NSRect(x: 212, y: 236, width: 268, height: 300), NSRect(x: 500, y: 236, width: 146, height: 300),
               NSRect(x: 666, y: 236, width: 146, height: 300)].enumerated() {
    NSColor.white.withAlphaComponent(i == 0 ? 0.13 : 0.08).setFill()
    NSBezierPath(roundedRect: r, xRadius: 36, yRadius: 36).fill()
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
