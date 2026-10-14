import AppKit
import CoreGraphics

// Generate a full-resolution, opaque iOS home-screen icon at build time.
let dest = URL(fileURLWithPath: CommandLine.arguments[1])
let px = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("Could not allocate icon image")
}
guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("No CGContext") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let ctx = graphics.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r,g,b,a])!
}
func ring(_ rect: CGRect, _ width: CGFloat, _ color: CGColor) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.strokeEllipse(in: rect)
}
let navy = rgba(0.035, 0.070, 0.125)
let midnight = rgba(0.075, 0.160, 0.260)
let teal = rgba(0.39, 0.96, 0.81)
let cyan = rgba(0.50, 0.73, 1.00)
let bg = CGGradient(colorsSpace: space, colors: [midnight, navy] as CFArray,
                    locations: [0.0, 1.0])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 1024, y: 1024),
                       end: CGPoint(x: 0, y: 0), options: [])

let aura = CGGradient(colorsSpace: space,
                      colors: [rgba(0.17,0.60,0.56,0.38), rgba(0.17,0.60,0.56,0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(aura,
    startCenter: CGPoint(x: 510, y: 514), startRadius: 80,
    endCenter: CGPoint(x: 510, y: 514), endRadius: 465,
    options: [])
// Optic outer bezel, illuminated crescent and pupil.
ctx.setShadow(offset: .zero, blur: 36, color: teal)
ring(CGRect(x: 192, y: 192, width: 640, height: 640), 36, teal)
ctx.setShadow(offset: .zero, blur: 0)
ring(CGRect(x: 244, y: 244, width: 536, height: 536), 5, rgba(0.48,0.75,1,0.48))
ctx.setFillColor(rgba(0.05,0.18,0.25,0.90))
ctx.fillEllipse(in: CGRect(x: 305, y: 305, width: 414, height: 414))
ctx.setShadow(offset: .zero, blur: 27, color: cyan)
ctx.setFillColor(cyan)
ctx.fillEllipse(in: CGRect(x: 448, y: 448, width: 128, height: 128))
ctx.setShadow(offset: .zero, blur: 0)
ring(CGRect(x: 390, y: 390, width: 244, height: 244), 17, teal)
// Four small direction markers feel like a camera reticle, not text.
ctx.setStrokeColor(rgba(0.8, 1.0, 0.96))
ctx.setLineCap(.round)
ctx.setLineWidth(23)
for angle in [0.0, Double.pi / 2, Double.pi, Double.pi * 1.5] {
    let x1 = 512 + 350 * cos(angle), y1 = 512 + 350 * sin(angle)
    let x2 = 512 + 389 * cos(angle), y2 = 512 + 389 * sin(angle)
    ctx.move(to: CGPoint(x: x1, y: y1))
    ctx.addLine(to: CGPoint(x: x2, y: y2))
    ctx.strokePath()
}
// Bottom accent arc, suggesting signal scanning.
ctx.setStrokeColor(rgba(0.35, 0.8, 1.0, 0.7))
ctx.setLineWidth(16)
ctx.addArc(center: CGPoint(x: 512, y: 512), radius: 431,
           startAngle: .pi * 1.12, endAngle: .pi * 1.87, clockwise: false)
ctx.strokePath()
ctx.flush()
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon PNG")
}
try png.write(to: dest)
print("Created icon: \(dest.path), \(png.count) bytes")
