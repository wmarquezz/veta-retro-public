// SPDX-License-Identifier: GPL-3.0-or-later
// Original elementary button symbols for the free PPSSPP atlas recipe.
import AppKit
let folder = CommandLine.arguments[1]
for name in ["cross", "circle", "square", "triangle"] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:32, pixelsHigh:32, bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB, bytesPerRow:0, bitsPerPixel:0)!
    let context = NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    NSColor.white.setStroke()
    let path = NSBezierPath(); path.lineWidth = 2.5; path.lineCapStyle = .round; path.lineJoinStyle = .round
    switch name {
    case "circle": path.appendOval(in:NSRect(x:5,y:5,width:22,height:22))
    case "square": path.appendRect(NSRect(x:6,y:6,width:20,height:20))
    case "triangle": path.move(to:NSPoint(x:16,y:28)); path.line(to:NSPoint(x:4,y:6)); path.line(to:NSPoint(x:28,y:6)); path.close()
    default: path.move(to:NSPoint(x:7,y:7)); path.line(to:NSPoint(x:25,y:25)); path.move(to:NSPoint(x:7,y:25)); path.line(to:NSPoint(x:25,y:7))
    }
    path.stroke(); NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:folder+"/"+name+".png"))
}
