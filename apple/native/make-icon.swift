// Deterministic production resize of the approved V/controller artwork; no redesign.
// swift make-icon.swift output.png [master.png] [size]
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
let output = URL(fileURLWithPath:CommandLine.arguments[1])
let source = URL(fileURLWithPath:CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "branding/v-control187/master.png")
let size = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 1024
let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(source as CFURL,nil)!,0,nil)!
let ctx = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.interpolationQuality = .high
ctx.draw(image,in:CGRect(x:0,y:0,width:size,height:size))
let destination = CGImageDestinationCreateWithURL(output as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(destination,ctx.makeImage()!,nil)
guard CGImageDestinationFinalize(destination) else {fatalError("Could not write icon")}
