import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("macos/OutlookFocus/Assets.xcassets/AppIcon.appiconset")
let chrome = root.appendingPathComponent("chrome-extension/public/icons")
let iconset = root.appendingPathComponent("build/OutlookFocus.iconset")
for dir in [assets, chrome, iconset] {
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}
func png(_ size: Int) throws -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  defer { NSGraphicsContext.restoreGraphicsState() }
  let ctx = NSGraphicsContext.current!.cgContext
  ctx.scaleBy(x: CGFloat(size) / 128, y: CGFloat(size) / 128)
  let bg = CGPath(
    roundedRect: CGRect(x: 4, y: 4, width: 120, height: 120), cornerWidth: 28, cornerHeight: 28,
    transform: nil)
  ctx.addPath(bg)
  ctx.setFillColor(CGColor(red: 0.12, green: 0.35, blue: 0.64, alpha: 1))
  ctx.fillPath()
  ctx.setStrokeColor(CGColor(red: 0.96, green: 0.98, blue: 1, alpha: 1))
  ctx.setLineWidth(6)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  ctx.addPath(
    CGPath(
      roundedRect: CGRect(x: 25, y: 38, width: 78, height: 54), cornerWidth: 8, cornerHeight: 8,
      transform: nil))
  ctx.strokePath()
  ctx.move(to: CGPoint(x: 29, y: 87))
  ctx.addLine(to: CGPoint(x: 64, y: 61))
  ctx.addLine(to: CGPoint(x: 99, y: 87))
  ctx.strokePath()
  ctx.setFillColor(CGColor(red: 0.12, green: 0.35, blue: 0.64, alpha: 1))
  ctx.fillEllipse(in: CGRect(x: 76, y: 16, width: 37, height: 37))
  ctx.setStrokeColor(CGColor(red: 0.56, green: 0.91, blue: 0.96, alpha: 1))
  ctx.setLineWidth(4)
  ctx.strokeEllipse(in: CGRect(x: 82, y: 22, width: 25, height: 25))
  ctx.move(to: CGPoint(x: 94.5, y: 17))
  ctx.addLine(to: CGPoint(x: 94.5, y: 26))
  ctx.move(to: CGPoint(x: 94.5, y: 43))
  ctx.addLine(to: CGPoint(x: 94.5, y: 52))
  ctx.move(to: CGPoint(x: 77, y: 34.5))
  ctx.addLine(to: CGPoint(x: 86, y: 34.5))
  ctx.move(to: CGPoint(x: 103, y: 34.5))
  ctx.addLine(to: CGPoint(x: 112, y: 34.5))
  ctx.strokePath()
  return rep.representation(using: .png, properties: [:])!
}
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = "icon_\(size)x\(size)\(scale==2 ? "@2x" : "").png"
    let data = try png(size * scale)
    try data.write(to: assets.appendingPathComponent(name))
    try data.write(to: iconset.appendingPathComponent(name))
    images.append([
      "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name,
    ])
  }
}
for size in [16, 32, 48, 128] {
  try png(size).write(to: chrome.appendingPathComponent("icon\(size).png"))
}
let info: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(
  to: assets.appendingPathComponent("Contents.json"))
print("Original OutlookFocus icons generated.")
