// The app's icon, drawn rather than exported: the Xool mark (four rounded
// triangles whose gaps form an X, over a Liquid-Glass glow) on a plate, as
// vector paths, so it is crisp at every size. The same shape is in
// Sources/XoolOS/Xool/XoolMark.swift (XoolMarkShape): keep the two alike.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")

/// A dev build (build.sh) puts the mark on a yellow plate, so the build from
/// a worktree and the installed app are told apart at a glance.
let dev = ProcessInfo.processInfo.environment["SEARCH_DEV"] == "1"
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// MARK: the mark's shape (XoolMarkShape, in a 1000-point square)

let unit: CGFloat = 1000
let gapHalf: CGFloat = 52
let cornerR: CGFloat = 46
let plateR: CGFloat = 270
let plateShape = CGPath(roundedRect: CGRect(x: 0, y: 0, width: unit, height: unit), cornerWidth: plateR, cornerHeight: plateR, transform: nil)

func rounded(_ path: CGPath, by radius: CGFloat) -> CGPath {
    let ring = path.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
    let core = path.subtracting(ring)
    let again = core.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
    return core.union(again)
}

let triangles: [CGPath] = {
    let c = unit / 2
    let apex = CGPoint(x: c, y: c - gapHalf)
    let top = CGMutablePath()
    top.move(to: apex)
    top.addLine(to: CGPoint(x: apex.x - 700, y: apex.y - 700))
    top.addLine(to: CGPoint(x: apex.x + 700, y: apex.y - 700))
    top.closeSubpath()
    return (0..<4).map { i in
        var t = CGAffineTransform(translationX: c, y: c).rotated(by: CGFloat(i) * .pi / 2).translatedBy(x: -c, y: -c)
        let cut = top.copy(using: &t) ?? top
        return rounded(cut.intersection(plateShape), by: cornerR)
    }
}()

/// The four as one path, as SVG path data (for the Icon Composer layer).
func svgData(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { e in
        let p = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: d += "M\(p[0].x) \(p[0].y) "
        case .addLineToPoint: d += "L\(p[0].x) \(p[0].y) "
        case .addQuadCurveToPoint: d += "Q\(p[0].x) \(p[0].y) \(p[1].x) \(p[1].y) "
        case .addCurveToPoint: d += "C\(p[0].x) \(p[0].y) \(p[1].x) \(p[1].y) \(p[2].x) \(p[2].y) "
        case .closeSubpath: d += "Z "
        @unknown default: break
        }
    }
    return d
}

func draw(_ size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    let rgb = CGColorSpaceCreateDeviceRGB()

    // Apple's grid: the shape takes 824 of 1024, and its corners are 22.37%.
    let s = size / 1024
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let radius = 824 * 0.2237 * s
    let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // A soft shadow under the plate, the way every icon on the Dock has one.
    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    (dev ? NSColor(srgbRed: 1.0, green: 0.8, blue: 0.2, alpha: 1) : NSColor(srgbRed: 0.075, green: 0.08, blue: 0.095, alpha: 1)).setFill()
    shape.fill()
    ctx.restoreGState()

    // The mark at 0.62 of the plate, centred; its path is y-down.
    let side = plate.width * 0.62
    ctx.saveGState()
    ctx.translateBy(x: plate.midX - side / 2, y: plate.midY + side / 2)
    ctx.scaleBy(x: side / unit, y: -side / unit)

    // Glass: a glow at the centre fading to nothing at the corners.
    ctx.saveGState()
    ctx.addPath(plateShape); ctx.clip()
    let glow = CGGradient(colorsSpace: rgb, colors: [
        CGColor(srgbRed: 0.74, green: 0.80, blue: 1.0, alpha: 1),
        CGColor(srgbRed: 0.46, green: 0.53, blue: 0.86, alpha: 0.7),
        CGColor(srgbRed: 0.30, green: 0.36, blue: 0.62, alpha: 0),
    ] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 500, y: 500), startRadius: 0, endCenter: CGPoint(x: 500, y: 500), endRadius: 707, options: [])
    ctx.restoreGState()

    // Silver triangles.
    let all = CGMutablePath()
    for t in triangles { all.addPath(t) }
    ctx.saveGState()
    ctx.addPath(all); ctx.clip()
    let silver = CGGradient(colorsSpace: rgb, colors: [
        CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1),
        CGColor(srgbRed: 0.72, green: 0.73, blue: 0.77, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(silver, start: CGPoint(x: 300, y: 0), end: CGPoint(x: 700, y: 1000), options: [])
    ctx.restoreGState()
    // A fine light rim, inside the edge.
    ctx.saveGState()
    ctx.addPath(all); ctx.clip()
    ctx.addPath(all)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
    ctx.setLineWidth(22); ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.restoreGState()
    return image
}

func write(_ image: NSImage, to url: URL, pixels: Int) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { return }
    // The bitmap is asked for at the pixel size, whatever the screen thinks.
    let sized = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    sized.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sized)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = sized.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = draw(CGFloat(pixels))
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(image, to: out.appendingPathComponent(name), pixels: pixels)
    }
}
print("drew: \(out.path)")

// The same icon as an Icon Composer document, when a second path is given:
// the plate and the mark as separate layers, so macOS 26 can show Dark, Clear
// and Tinted. build.sh compiles it with actool; the images above stay the .icns.
if CommandLine.arguments.count > 2 {
    let doc = URL(fileURLWithPath: CommandLine.arguments[2])
    let assets = doc.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: doc)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    let width = 1024 * 0.62
    let all = CGMutablePath()
    for t in triangles { all.addPath(t) }
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(width)" viewBox="0 0 1000 1000">\
    <path fill-rule="nonzero" fill="#D9DBE2" d="\(svgData(all))"/></svg>
    """
    try svg.write(to: assets.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)

    let ink = #"{ "solid" : "srgb:0.07500,0.08000,0.09500,1.00000" }"#
    let yellow = #"{ "solid" : "srgb:1.00000,0.80000,0.20000,1.00000" }"#
    let white = #"{ "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" }"#
    let plate = dev ? yellow : ink
    let json = """
    {
      "fill" : \(plate),
      "groups" : [
        {
          "layers" : [
            {
              "name" : "mark",
              "image-name" : "mark.svg",
              "glass" : false,
              "fill-specializations" : [
                { "value" : \(white) },
                { "appearance" : "tinted", "value" : \(white) }
              ]
            }
          ],
          "shadow" : { "kind" : "none", "opacity" : 0.5 },
          "specular" : false,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }
    """
    try json.write(to: doc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("wrote: \(doc.path)")
}
