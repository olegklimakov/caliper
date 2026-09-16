// Normalises the generated artwork into the master 1024×1024 app icon:
// finds the tile in the source image, scales it onto Apple's icon grid
// (an 824×824 shape centred in a 1024 canvas) and clips it to the system's
// continuous-corner shape, so the corners match every other Mac icon and the
// margins are the ones the Dock expects.
//
// `--dev` stamps the development build's badge over the same artwork, so the
// two icons cannot drift apart: one crop, one grid, one shape, one file.
//
// Usage: swift Scripts/make_icon.swift <source.png> <out.png> [--dev]

import AppKit
import CoreText
import SwiftUI

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_icon: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 || (arguments.count == 4 && arguments[3] == "--dev") else {
    fail("usage: make_icon.swift <source.png> <out.png> [--dev]")
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let isDev = arguments.count == 4

guard
    let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
    let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fail("cannot read \(sourceURL.path)")
}

let canvas: CGFloat = 1024
let tile: CGFloat = 824              // Apple's macOS icon grid.
/// 185.4 pt of corner on an 824 pt shape, which is what the grid specifies.
let cornerRatio: CGFloat = 0.225
/// The render paints its own bright rim just inside the tile edge; on a
/// transparent canvas that rim reads as a sticker outline, so the artwork is
/// drawn this much oversized and the clip takes the rim with it.
let bleed: CGFloat = 8
/// A tile pixel is darker than this. The mark inside the tile is lighter in
/// places, which is why the scan below takes a bounding box rather than a mask.
let tileLuma = 128.0

// The development badge. A band rather than a tint or a letter in a corner
// because the icon has to be told apart at 16 pt, where the text below is gone
// and a saturated strip along the bottom of a near-black tile is not.
/// Apple's systemOrange, dark appearance — the badge sits on a dark tile.
let badgeColour = CGColor(red: 1, green: 0.624, blue: 0.039, alpha: 1)
let badgeHeightRatio: CGFloat = 0.22     // Of the tile.
let badgeLabel = "DEV"
let badgeTracking: CGFloat = 0.1         // Of the point size.

/// The tile is the dark region in the render; the surround is the generator's
/// pale backdrop.
///
/// Scanning for it means the generator does not have to centre the tile, or
/// hand back a square canvas — neither of which it does. It also means the
/// assumption is worth checking: a render whose surround is *not* pale gives a
/// box the size of the whole canvas, and that must fail loudly rather than
/// quietly produce an icon with the backdrop baked into it.
func tileBounds(of image: CGImage) -> CGRect {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard
        let colourSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        fail("cannot read the pixels of \(sourceURL.lastPathComponent)")
    }
    // Composited on white first: a transparent backdrop must read as "not
    // tile" the same way an opaque pale one does.
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let luma = 0.299 * Double(pixels[offset])
                + 0.587 * Double(pixels[offset + 1])
                + 0.114 * Double(pixels[offset + 2])
            guard luma < tileLuma else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else {
        fail("no tile in \(sourceURL.lastPathComponent) — nothing in it is dark")
    }
    let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    // A box that fills the render is the scan reporting the whole picture, not
    // a tile: the surround is as dark as the tile, and cropping to this would
    // bake it into the icon.
    guard bounds.width < CGFloat(width) * 0.99, bounds.height < CGFloat(height) * 0.99 else {
        fail("\(sourceURL.lastPathComponent) has no pale surround — the tile fills the render")
    }
    // Squeezed into a square shape below, so a tile that is not one would be
    // distorted — invisibly at half a percent, plainly at five.
    let aspect = bounds.width / bounds.height
    guard abs(aspect - 1) < 0.02 else {
        fail(
            "the tile in \(sourceURL.lastPathComponent) is "
                + "\(Int(bounds.width))×\(Int(bounds.height)), too far from square to fit the grid"
        )
    }
    return bounds
}

let bounds = tileBounds(of: artwork)
// `cropping(to:)` measures from the top-left, which is where the scan found it.
guard let cropped = artwork.cropping(to: bounds) else {
    fail("cannot crop the tile out of \(sourceURL.lastPathComponent)")
}

guard
    let colourSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
        data: nil,
        width: Int(canvas),
        height: Int(canvas),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colourSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    fail("cannot create the \(Int(canvas))×\(Int(canvas)) canvas")
}
context.interpolationQuality = .high

let inset = (canvas - tile) / 2
let shape = CGRect(x: inset, y: inset, width: tile, height: tile)
// SwiftUI's continuous style is the system's squircle; a plain rounded rect
// would give the corners a visibly different curvature to every neighbour in
// the Dock.
let path = Path(
    roundedRect: shape,
    cornerRadius: tile * cornerRatio,
    style: .continuous
).cgPath
context.addPath(path)
context.clip()
context.draw(cropped, in: shape.insetBy(dx: -bleed, dy: -bleed))

if isDev {
    // Drawn inside the clip, so the band's lower corners follow the squircle
    // instead of squaring it off.
    let band = CGRect(x: shape.minX, y: shape.minY, width: tile, height: tile * badgeHeightRatio)
    context.setFillColor(badgeColour)
    context.fill(band)

    let pointSize = band.height * 0.58
    let tracking = pointSize * badgeTracking
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(
            string: badgeLabel,
            attributes: [
                .font: NSFont.systemFont(ofSize: pointSize, weight: .heavy),
                .kern: tracking,
                // CoreText's own key: `.foregroundColor` carries an NSColor,
                // and CTLineDraw wants a CGColor.
                kCTForegroundColorAttributeName as NSAttributedString.Key:
                    CGColor(gray: 0.08, alpha: 1),
            ]
        )
    )
    // Optical bounds rather than the typographic ones: "DEV" is three caps with
    // no descender, and centring it on the line height would sit it low.
    let text = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    context.textPosition = CGPoint(
        // Kerning is applied after the last glyph too, so the run is `tracking`
        // wider than the letters are.
        x: band.midX - (text.width - tracking) / 2 - text.minX,
        y: band.midY - text.height / 2 - text.minY
    )
    CTLineDraw(line, context)
}

guard
    let output = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, "public.png" as CFString, 1, nil
    )
else {
    fail("cannot write \(outputURL.path)")
}
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("cannot finish writing \(outputURL.path)")
}

let box = bounds.integral
print("tile found at \(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))×\(Int(box.height)) → \(outputURL.lastPathComponent)")
