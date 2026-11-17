import AppKit
for name in ["moon.zzz","sun.max.fill","wifi","battery.100percent","magnifyingglass","switch.2"] {
  let cfg = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular).applying(.init(paletteColors: [.white]))
  let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(img.size.width*2), pixelsHigh: Int(img.size.height*2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = img.size
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  img.draw(in: NSRect(origin: .zero, size: img.size)); NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name + ".png"))
  print(name, img.size)
}
