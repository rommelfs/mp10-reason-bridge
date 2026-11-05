import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Build-time asset packaging only: no API keys, network, or image-generation
// services are needed to build the app from the checked-in source artwork.
func fail(_ message: String) -> Never {
 fputs("Icon build failed: \(message)\n", stderr)
 exit(1)
}
guard CommandLine.arguments.count == 5 else {
 fail("usage: IconBuilder source.png output.iconset output-menu.pdf output.icns")
}
let sourceURL=URL(fileURLWithPath:CommandLine.arguments[1])
let iconsetURL=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
let menuURL=URL(fileURLWithPath:CommandLine.arguments[3])
let icnsURL=URL(fileURLWithPath:CommandLine.arguments[4])
guard let source=CGImageSourceCreateWithURL(sourceURL as CFURL,nil),
      let image=CGImageSourceCreateImageAtIndex(source,0,nil),
      image.width == image.height,image.width >= 1024 else {
 fail("source must be a square PNG at least 1024 pixels wide")
}
try FileManager.default.createDirectory(at:iconsetURL,withIntermediateDirectories:true)
let colorSpace=CGColorSpace(name:CGColorSpace.sRGB)!
let representations=[(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
guard let icns=CGImageDestinationCreateWithURL(icnsURL as CFURL,UTType.icns.identifier as CFString,representations.count,nil) else {fail("could not create ICNS")}
for (points,scale) in representations {
 let size=points*scale
 guard let context=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,
                             bytesPerRow:size*4,space:colorSpace,
                             bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
  fail("could not create \(size)-pixel bitmap")
 }
 context.interpolationQuality = .high
 context.clear(CGRect(x:0,y:0,width:size,height:size))
 context.draw(image,in:CGRect(x:0,y:0,width:size,height:size))
 guard let resized=context.makeImage() else { fail("could not resize source") }
 let filename="icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
 let url=iconsetURL.appendingPathComponent(filename)
 guard let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {fail("could not create PNG")}
 CGImageDestinationAddImage(destination,resized,nil)
 guard CGImageDestinationFinalize(destination) else {fail("could not write \(filename)")}
 let resolution=[kCGImagePropertyDPIWidth:72*scale,kCGImagePropertyDPIHeight:72*scale] as CFDictionary
 CGImageDestinationAddImage(icns,resized,resolution)
}
guard CGImageDestinationFinalize(icns),let check=CGImageSourceCreateWithURL(icnsURL as CFURL,nil),CGImageSourceGetCount(check) == representations.count else {fail("ICNS validation failed")}
let sizes=(0..<CGImageSourceGetCount(check)).compactMap { CGImageSourceCreateImageAtIndex(check,$0,nil)?.width }.sorted()
guard sizes == representations.map({ $0.0*$0.1 }).sorted() else {fail("missing ICNS sizes")}
// A vector template, rather than a scaled-down full-color app icon: macOS
// supplies the foreground color for light/dark menu bars and highlighted menus.
var bounds=CGRect(x:0,y:0,width:18,height:18)
guard let pdf=CGContext(menuURL as CFURL,mediaBox:&bounds,nil) else {fail("could not create menu PDF")}
pdf.beginPDFPage(nil)
pdf.setStrokeColor(CGColor(gray:0,alpha:1))
pdf.setFillColor(CGColor(gray:0,alpha:1))
pdf.setLineWidth(1.9)
pdf.setLineCap(.round)
pdf.setLineJoin(.round)
pdf.move(to:CGPoint(x:2.6,y:3.5))
pdf.addLine(to:CGPoint(x:2.6,y:8.4))
pdf.addCurve(to:CGPoint(x:9,y:14.8),control1:CGPoint(x:2.6,y:12.2),control2:CGPoint(x:5.4,y:14.8))
pdf.addCurve(to:CGPoint(x:15.4,y:8.4),control1:CGPoint(x:12.6,y:14.8),control2:CGPoint(x:15.4,y:12.2))
pdf.addLine(to:CGPoint(x:15.4,y:3.5))
pdf.strokePath()
for x:CGFloat in [1.2,13.7] {
 pdf.move(to:CGPoint(x:x,y:3.5));pdf.addLine(to:CGPoint(x:x+3.1,y:3.5));pdf.strokePath()
}
pdf.move(to:CGPoint(x:7.2,y:5.5));pdf.addLine(to:CGPoint(x:11.2,y:8))
pdf.addLine(to:CGPoint(x:7.2,y:10.5));pdf.closePath();pdf.fillPath()
pdf.endPDFPage();pdf.closePDF()
print("Prepared app icon sizes and vector menu-bar template.")
