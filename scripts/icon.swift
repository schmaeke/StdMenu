// Draws the application icon into an .iconset directory: `swift scripts/icon.swift <dir>`.
//
// A white menu on black: the chosen item as a wide pill between two shorter items, on Apple's
// macOS icon grid (an 824 pt body with 185.4 pt corners on a 1024 pt canvas).
import AppKit

func draw(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let scale = CGFloat(pixels) / 1024
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.scaleBy(x: scale, y: scale)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor(white: 0, alpha: 0.3).cgColor)
    context.addPath(CGPath(roundedRect: body, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil))
    context.setFillColor(.black)
    context.fillPath()
    context.restoreGState()

    func pill(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let rect = CGRect(x: body.minX + x * body.width, y: body.midY + (y - height / 2) * body.height,
                          width: width * body.width, height: height * body.height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
                               transform: nil))
    }
    pill(x: 0.20, y: 0.19, width: 0.42, height: 0.06)
    pill(x: 0.15, y: 0, width: 0.70, height: 0.16)
    pill(x: 0.20, y: -0.19, width: 0.30, height: 0.06)
    context.setFillColor(.white)
    context.fillPath()
    return rep
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try draw(pixels: points * scale).representation(using: .png, properties: [:])!
            .write(to: directory.appending(path: name))
    }
}
