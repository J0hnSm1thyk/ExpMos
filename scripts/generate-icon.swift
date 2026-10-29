import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale); transform.concat()
    NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.92, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 35, y: 35, width: 954, height: 954), xRadius: 215, yRadius: 215).fill()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    shadow.shadowBlurRadius = 38; shadow.shadowOffset = NSSize(width: 0, height: -20)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor(calibratedRed: 0.19, green: 0.42, blue: 0.35, alpha: 1).setFill()
    let back = NSBezierPath(roundedRect: NSRect(x: 175, y: 260, width: 674, height: 470), xRadius: 55, yRadius: 55)
    back.fill()
    NSBezierPath(roundedRect: NSRect(x: 175, y: 635, width: 294, height: 154), xRadius: 45, yRadius: 45).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.85, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 220, y: 345, width: 582, height: 325), xRadius: 30, yRadius: 30).fill()
    let front = NSBezierPath(roundedRect: NSRect(x: 155, y: 240, width: 714, height: 355), xRadius: 55, yRadius: 55)
    NSGradient(starting: NSColor(calibratedRed: 0.27, green: 0.61, blue: 0.48, alpha: 1), ending: NSColor(calibratedRed: 0.17, green: 0.47, blue: 0.37, alpha: 1))!.draw(in: front, angle: 90)
    NSColor.white.withAlphaComponent(0.9).setFill()
    for y in [360, 430] {
        NSBezierPath(roundedRect: NSRect(x: 283, y: y, width: 44, height: 25), xRadius: 12, yRadius: 12).fill()
        NSBezierPath(roundedRect: NSRect(x: 365, y: y, width: y == 430 ? 321 : 225, height: 25), xRadius: 12, yRadius: 12).fill()
    }
    image.unlockFocus()
    let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    var names: [String] = []
    if size <= 512 { names.append("icon_\(size)x\(size).png") }
    if size >= 32 { names.append("icon_\(size / 2)x\(size / 2)@2x.png") }
    for name in names { try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name)) }
}
