// Draws the backdrop of the disk image window.
//
// The window is the first thing anyone sees of this app, and the stock one — a
// bare folder holding a bare bundle — does not even offer the /Applications
// folder the instructions tell people to drag onto. This draws the other half
// of that sentence: a light plate under each icon, and between them the app's
// own metaphor, a rule measuring the distance across.
//
// An arrow would say the same thing in the same words every other installer
// uses. A scale says it in this app's.
//
// Nothing here knows where Finder will actually put the icons. The slot
// centres below and the ones passed to `create-dmg` in Scripts/release.sh are
// one fact in two files; they are named in both and must agree.
//
// Usage: swift Scripts/make_dmg_background.swift <out.png> <scale>

import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_dmg_background: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Double(arguments[2]), scale > 0 else {
    fail("usage: make_dmg_background.swift <out.png> <scale>")
}
let outputURL = URL(fileURLWithPath: arguments[1])

// MARK: - The layout both files share

/// Window content size in points. `create-dmg --window-size` must match.
let width: CGFloat = 660
let height: CGFloat = 420
/// Icon slot centres, in points from the *bottom* left — Core Graphics' origin.
/// `create-dmg` measures from the top left, so its y is `height - y` of these.
let appSlot = CGPoint(x: 165, y: 232)
let applicationsSlot = CGPoint(x: 495, y: 232)
/// What `create-dmg --icon-size` is told. The plates are sized around it and
/// the rule spans what is left between them.
let iconSize: CGFloat = 128

// MARK: - Palette
//
// Taken off the app icon: a near-black tile, brushed steel, and the neon trio.
// Fixed rather than dynamic, because a disk image backdrop is a picture —
// Finder never re-renders it for the other appearance.

let ink = NSColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1)
let plateLight = NSColor(red: 0.96, green: 0.965, blue: 0.975, alpha: 1)
let plateDark = NSColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1)
let steelLight = NSColor(red: 0.84, green: 0.85, blue: 0.86, alpha: 1)
let steelDark = NSColor(red: 0.52, green: 0.54, blue: 0.57, alpha: 1)
let tickColour = NSColor(white: 0.62, alpha: 1)
let captionColour = NSColor(white: 0.45, alpha: 1)
let violet = NSColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1)
let blue = NSColor(red: 0.13, green: 0.55, blue: 1.00, alpha: 1)
let green = NSColor(red: 0.20, green: 0.80, blue: 0.35, alpha: 1)

// MARK: - Canvas

let pixelWidth = Int((width * scale).rounded())
let pixelHeight = Int((height * scale).rounded())
guard
    let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    fail("cannot create a \(pixelWidth)×\(pixelHeight) context")
}
context.scaleBy(x: scale, y: scale)

let graphics = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = graphics

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Fills a shape with a vertical two-stop gradient.
func fillVertically(_ path: CGPath, from top: NSColor, to bottom: NSColor, in rect: CGRect) {
    guard
        let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: [top.cgColor, bottom.cgColor] as CFArray,
            locations: [0, 1]
        )
    else { fail("cannot build a gradient") }
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: rect.maxY),
        end: CGPoint(x: 0, y: rect.minY),
        options: []
    )
    context.restoreGState()
}

// MARK: - Ground

context.setFillColor(ink.cgColor)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

// A slow lift towards the middle, so the panel does not read as a flat black
// rectangle on a dark desktop. Two stops and a wide radius: any more structure
// and it starts competing with the icons for attention.
if let glow = CGGradient(
    colorsSpace: sRGB,
    colors: [NSColor(white: 0.16, alpha: 1).cgColor, ink.cgColor] as CFArray,
    locations: [0, 1]
) {
    context.saveGState()
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: width / 2, y: height * 0.56),
        startRadius: 0,
        endCenter: CGPoint(x: width / 2, y: height * 0.56),
        endRadius: width * 0.62,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()
}

// MARK: - The two plates
//
// A light slab under each icon. It gives the dark app tile something to sit
// against — a near-black icon on a near-black ground is a hole — and it makes
// the two drop points read as places rather than as coordinates.
//
// Under the name as well as the icon. Finder writes the name in the system's
// own text colour, which on a light appearance is near-black — and near-black
// on this backdrop is invisible. The plate is what the name is legible
// against, so it has to reach past it.

/// Padding between the icon's box and the edge of the plate it sits on.
///
/// Not equal on every side: the extra room at the bottom is the line Finder
/// writes the item's name on. Padded evenly, the plate ends halfway through
/// that line and cuts the name in two — half on the slab, half on the ground.
let plateInset = (top: CGFloat(20), sides: CGFloat(20), bottom: CGFloat(46))
let plateWidth = iconSize + 2 * plateInset.sides
let plateHeight = iconSize + plateInset.top + plateInset.bottom
let plateRadius: CGFloat = 30

for slot in [appSlot, applicationsSlot] {
    let rect = CGRect(
        x: slot.x - plateWidth / 2,
        y: slot.y - iconSize / 2 - plateInset.bottom,
        width: plateWidth,
        height: plateHeight
    )
    let plate = CGPath(
        roundedRect: rect,
        cornerWidth: plateRadius,
        cornerHeight: plateRadius,
        transform: nil
    )
    // Cast down and away, so the slab lifts off the ground rather than looking
    // painted onto it.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -6),
        blur: 22,
        color: NSColor(white: 0, alpha: 0.55).cgColor
    )
    context.setFillColor(plateLight.cgColor)
    context.addPath(plate)
    context.fillPath()
    context.restoreGState()

    fillVertically(plate, from: plateLight, to: plateDark, in: rect)
}

// MARK: - The rule between them

/// A little air between each plate and the end of the rule.
let clearance: CGFloat = 16
let spanStart = appSlot.x + plateWidth / 2 + clearance
let spanEnd = applicationsSlot.x - plateWidth / 2 - clearance
let beamY = appSlot.y
guard spanEnd - spanStart > 60 else {
    fail("the plates leave no room between them for the rule")
}

let beamHeight: CGFloat = 8
let beamRect = CGRect(
    x: spanStart,
    y: beamY - beamHeight / 2,
    width: spanEnd - spanStart,
    height: beamHeight
)
fillVertically(
    CGPath(
        roundedRect: beamRect,
        cornerWidth: beamHeight / 2,
        cornerHeight: beamHeight / 2,
        transform: nil
    ),
    from: steelLight,
    to: steelDark,
    in: beamRect
)

// MARK: - The scale

// Ticks above the beam, every fifth one long: the detail that makes the shape
// read as an instrument rather than as a divider.
let tickCount = 13
let tickSpacing = (spanEnd - spanStart) / CGFloat(tickCount - 1)
context.setStrokeColor(tickColour.cgColor)
context.setLineWidth(1)
for index in 0..<tickCount {
    let x = (spanStart + CGFloat(index) * tickSpacing).rounded() + 0.5
    let length: CGFloat = index % 5 == 0 ? 15 : 8
    context.move(to: CGPoint(x: x, y: beamY + beamHeight / 2 + 3))
    context.addLine(to: CGPoint(x: x, y: beamY + beamHeight / 2 + 3 + length))
}
context.strokePath()

// MARK: - The reading

// The neon trio from the icon, run under the beam as the value the instrument
// is showing. It is the one piece of colour in the window, so it stays
// hairline-thin and dim.
if let reading = CGGradient(
    colorsSpace: sRGB,
    colors: [violet.cgColor, blue.cgColor, green.cgColor] as CFArray,
    locations: [0, 0.5, 1]
) {
    let bar = CGRect(
        x: spanStart,
        y: beamY - beamHeight / 2 - 12,
        width: spanEnd - spanStart,
        height: 3
    )
    context.saveGState()
    context.setShadow(offset: .zero, blur: 12, color: blue.withAlphaComponent(0.55).cgColor)
    context.addPath(
        CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
    )
    context.clip()
    context.drawLinearGradient(
        reading,
        start: CGPoint(x: bar.minX, y: 0),
        end: CGPoint(x: bar.maxX, y: 0),
        options: []
    )
    context.restoreGState()
}

// MARK: - Caption

// Finder writes the two names under the icons; this is the verb between them.
// Drawn into the picture rather than left to the window, because a disk image
// has nowhere else to put a sentence.
let caption = "Drag Caliper onto Applications"
let captionAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: captionColour,
    .kern: 0.6,
]
let captionSize = (caption as NSString).size(withAttributes: captionAttributes)
(caption as NSString).draw(
    at: CGPoint(x: (width - captionSize.width) / 2, y: 84),
    withAttributes: captionAttributes
)

// MARK: - Write

NSGraphicsContext.current = nil
guard let image = context.makeImage() else { fail("nothing was drawn") }
guard
    let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        "public.png" as CFString,
        1,
        nil
    )
else {
    fail("cannot write \(outputURL.path)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("cannot finalise \(outputURL.path)")
}
