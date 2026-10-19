import AppKit

// Icono de FluFlu: onda de voz blanca sobre un degradado violeta → turquesa, en la plantilla de
// iconos de macOS (lienzo 1024, cuerpo 824 con esquinas de 185 y sombra suave).
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let colors = [NSColor(srgbRed: 0.42, green: 0.32, blue: 0.98, alpha: 1).cgColor,
              NSColor(srgbRed: 0.16, green: 0.76, blue: 0.83, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
// Brillo superior sutil para dar volumen.
let gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 512), options: [])

// Onda: barras redondeadas simétricas.
let heights: [Double] = [0.22, 0.42, 0.68, 0.92, 1.0, 0.92, 0.68, 0.42, 0.22]
let barWidth = 46.0, gap = 30.0, maxHeight = 470.0
let total = Double(heights.count) * barWidth + Double(heights.count - 1) * gap
var x = 512 - total / 2
ctx.setFillColor(NSColor.white.cgColor)
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.18).cgColor)
for h in heights {
    let height = maxHeight * h
    let bar = CGRect(x: x, y: 512 - height / 2, width: barWidth, height: height)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.fillPath()
    x += barWidth + gap
}
ctx.restoreGState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
