import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png")
let image = NSImage(size: NSSize(width: 1024, height: 1024))

image.lockFocus()

let base = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 216, yRadius: 216)
NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.24, blue: 0.37, alpha: 1),
    NSColor(calibratedRed: 0.19, green: 0.30, blue: 0.57, alpha: 1)
])!.draw(in: base, angle: -32)

NSColor(calibratedRed: 0.45, green: 0.61, blue: 0.82, alpha: 0.55).setStroke()
base.lineWidth = 9
base.stroke()

let keycap = NSBezierPath(roundedRect: NSRect(x: 218, y: 222, width: 588, height: 588), xRadius: 142, yRadius: 142)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0.03, alpha: 0.35)
shadow.shadowBlurRadius = 42
shadow.shadowOffset = NSSize(width: 0, height: -28)
shadow.set()
NSColor(calibratedRed: 0.89, green: 0.95, blue: 1.0, alpha: 1).setFill()
keycap.fill()
NSGraphicsContext.restoreGraphicsState()

let face = NSBezierPath(roundedRect: NSRect(x: 261, y: 265, width: 502, height: 502), xRadius: 108, yRadius: 108)
NSColor(calibratedRed: 0.14, green: 0.27, blue: 0.43, alpha: 1).setFill()
face.fill()

let center = NSPoint(x: 512, y: 480)
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: 169, startAngle: 200, endAngle: -20, clockwise: true)
track.lineWidth = 56
track.lineCapStyle = .round
NSColor(calibratedRed: 0.40, green: 0.54, blue: 0.70, alpha: 1).setStroke()
track.stroke()

let filled = NSBezierPath()
filled.appendArc(withCenter: center, radius: 169, startAngle: 200, endAngle: 54, clockwise: true)
filled.lineWidth = 56
filled.lineCapStyle = .round
NSColor(calibratedRed: 0.38, green: 0.32, blue: 0.89, alpha: 1).setStroke()
filled.stroke()

let needle = NSBezierPath()
needle.move(to: center)
needle.line(to: NSPoint(x: 608, y: 616))
needle.lineWidth = 28
needle.lineCapStyle = .round
NSColor(calibratedRed: 0.96, green: 0.98, blue: 1, alpha: 1).setStroke()
needle.stroke()
NSColor(calibratedRed: 0.96, green: 0.98, blue: 1, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 486, y: 454, width: 52, height: 52)).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render app icon")
}
try png.write(to: output)
