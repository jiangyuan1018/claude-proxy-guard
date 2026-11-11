import AppKit
import ImageIO
import UniformTypeIdentifiers

precondition(CommandLine.arguments.count == 4, "Usage: RenderIcons <resources> <iconset> <optional-png-path>")
let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let custom = URL(fileURLWithPath: CommandLine.arguments[3])
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: 1)
}

let image: CGImage
if FileManager.default.fileExists(atPath: custom.path) {
    guard let source = CGImageSourceCreateWithURL(custom as CFURL, nil),
          let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil),
          loaded.width == loaded.height else {
        fatalError("assets/Mascot.png must be a readable square image.")
    }
    image = loaded
} else {
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                            bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color(0.16, 0.11, 0.23))
    context.addPath(CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), cornerWidth: 180, cornerHeight: 180, transform: nil))
    context.fillPath()
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 822))
    shield.addLine(to: CGPoint(x: 770, y: 712))
    shield.addLine(to: CGPoint(x: 734, y: 394))
    shield.addLine(to: CGPoint(x: 512, y: 196))
    shield.addLine(to: CGPoint(x: 290, y: 394))
    shield.addLine(to: CGPoint(x: 254, y: 712))
    shield.closeSubpath()
    context.setStrokeColor(color(0.81, 0.67, 1))
    context.setLineWidth(52)
    context.setLineJoin(.round)
    context.addPath(shield)
    context.strokePath()
    context.setStrokeColor(color(0.72, 0.93, 0.81))
    context.setLineWidth(60)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 390, y: 520))
    context.addLine(to: CGPoint(x: 480, y: 430))
    context.addLine(to: CGPoint(x: 652, y: 622))
    context.strokePath()
    image = context.makeImage()!
}

func render(_ url: URL, size: Int) {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(output))
}

render(resources.appendingPathComponent("Mascot.png"), size: 1024)
render(resources.appendingPathComponent("MascotMenu.png"), size: 20)
render(resources.appendingPathComponent("MascotMenu@2x.png"), size: 40)
for (name, size) in [("icon_16x16.png",16),("icon_16x16@2x.png",32),("icon_32x32.png",32),("icon_32x32@2x.png",64),("icon_128x128.png",128),("icon_128x128@2x.png",256),("icon_256x256.png",256),("icon_256x256@2x.png",512),("icon_512x512.png",512),("icon_512x512@2x.png",1024)] {
    render(iconset.appendingPathComponent(name), size: size)
}
