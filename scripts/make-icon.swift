#!/usr/bin/env swift
//
// Renders Whirr's app icon — a 3-bladed fan on a warm gradient squircle —
// at every macOS-required size, then packs them into AppIcon.icns via
// `iconutil`. Output: Sources/Whirr/Resources/AppIcon.icns.
//
// Reproducible by design: re-running this script regenerates pixel-
// identical output (no random salt, no platform-dependent rasterization
// noise beyond what CoreGraphics itself contributes). Commit the .icns
// alongside the script so the build doesn't depend on this running.
//
// Run:    swift scripts/make-icon.swift
//

import AppKit
import CoreGraphics

// MARK: - Configuration

let here = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()  // scripts/
    .deletingLastPathComponent()  // repo root
let resourcesDir = here
    .appendingPathComponent("Sources/Whirr/Resources")
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset")
let icnsPath = resourcesDir.appendingPathComponent("AppIcon.icns")

// macOS .iconset members: 16, 32, 128, 256, 512 each at @1x and @2x.
let sizes: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

// MARK: - Drawing

/// Render the icon at the given pixel size and return PNG data. All
/// proportions are expressed as fractions of `size` so the icon scales
/// crisply at every resolution.
func renderIcon(pixelSize: Int) -> Data {
    let size = CGFloat(pixelSize)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    drawSquircleBackground(ctx: ctx, size: size)
    drawFan(ctx: ctx, size: size)

    return bitmap.representation(using: .png, properties: [:])!
}

/// macOS Big-Sur-and-later squircle, filled with a warm vertical gradient.
/// Corner radius 22.37% matches Apple's HIG icon mask.
func drawSquircleBackground(ctx: CGContext, size: CGFloat) {
    let cornerRadius = size * 0.2237
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Cool blue gradient — Material "blue 400" at top, "blue 800" at
    // bottom. Cool palette reads as "diagnostic" / "calm" instead of
    // "alarm," and reserves warm colors for the menu bar's actual
    // severity badges where they need to stand out.
    let topColor = CGColor(
        srgbRed: 0.259, green: 0.647, blue: 0.961, alpha: 1.0  // #42A5F5
    )
    let bottomColor = CGColor(
        srgbRed: 0.082, green: 0.396, blue: 0.753, alpha: 1.0  // #1565C0
    )
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [topColor, bottomColor] as CFArray,
        locations: [0.0, 1.0]
    )!
    // Geometry note: CoreGraphics origin is bottom-left, so start = top
    // means y = size.
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    ctx.restoreGState()

    // Subtle inner highlight along the top edge — gives the squircle a
    // little life without looking like a 2013-era glassy button.
    let highlightRect = CGRect(x: 0, y: size * 0.6, width: size, height: size * 0.4)
    let highlightPath = CGPath(
        roundedRect: rect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(highlightPath)
    ctx.clip()
    let highlightGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        highlightGradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: highlightRect.minY),
        options: []
    )
    ctx.restoreGState()
}

/// Three-blade fan, centered, in white. Three blades read more
/// distinctively at small sizes than four (the pinwheel asymmetry is
/// clear even at 16×16) and match the "Whirr" brand vibe better than a
/// boxy four-blade rotor.
func drawFan(ctx: CGContext, size: CGFloat) {
    let center = CGPoint(x: size / 2, y: size / 2)
    // Blade tip reaches ~38% of the icon — gives breathing room around the
    // squircle edge so the icon doesn't feel cramped at small sizes.
    let outerRadius = size * 0.38
    let hubRadius = size * 0.085

    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)

    let blade = bladePath(outerRadius: outerRadius, hubRadius: hubRadius)
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    // Three blades, 120° apart. Soft shadow on each so they read as
    // separate shapes even when adjacent edges touch the hub.
    for i in 0..<3 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * 0.005),
            blur: size * 0.015,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18)
        )
        ctx.rotate(by: CGFloat(i) * (2 * .pi / 3))
        ctx.addPath(blade)
        ctx.setFillColor(white)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Hub on top of the blades — covers the seams where the three blades
    // converge and gives the icon a clear focal point.
    let hub = CGPath(
        ellipseIn: CGRect(
            x: -hubRadius, y: -hubRadius,
            width: hubRadius * 2, height: hubRadius * 2
        ),
        transform: nil
    )
    ctx.addPath(hub)
    ctx.setFillColor(white)
    ctx.fillPath()

    // Small accent dot inside the hub — adds detail at large sizes
    // without registering as anything at small sizes.
    let dotRadius = hubRadius * 0.42
    let dot = CGPath(
        ellipseIn: CGRect(
            x: -dotRadius, y: -dotRadius,
            width: dotRadius * 2, height: dotRadius * 2
        ),
        transform: nil
    )
    ctx.addPath(dot)
    // Accent dot matches the gradient's bottom color so the hub reads as
    // a small "drilled" detail rather than a foreign accent.
    ctx.setFillColor(CGColor(srgbRed: 0.082, green: 0.396, blue: 0.753, alpha: 1.0))
    ctx.fillPath()

    ctx.restoreGState()
}

/// One blade, anchored at the origin, extending into the +x half-plane.
/// Shape: comma / teardrop with the wide end at the outer rim and a
/// curved sweep suggesting rotation. Rendered by `drawFan` rotated for
/// each blade.
func bladePath(outerRadius: CGFloat, hubRadius: CGFloat) -> CGPath {
    let path = CGMutablePath()

    // Angular spread of the blade at the outer rim — wide enough to read
    // as a substantial blade, narrow enough to leave gaps between blades.
    let outerArc: CGFloat = .pi / 4.2  // ~43°
    let outerTopAngle: CGFloat = outerArc
    let outerBottomAngle: CGFloat = -outerArc

    // Sweep direction: blades curve clockwise (when viewed with +y up).
    // This is the "leading edge" / "trailing edge" asymmetry that makes
    // the fan look like it's spinning.

    let leadingHub = CGPoint(
        x: hubRadius * cos(.pi / 2.1),
        y: hubRadius * sin(.pi / 2.1)
    )
    let trailingHub = CGPoint(
        x: hubRadius * cos(-.pi / 2.1),
        y: hubRadius * sin(-.pi / 2.1)
    )
    let leadingTip = CGPoint(
        x: outerRadius * cos(outerTopAngle),
        y: outerRadius * sin(outerTopAngle)
    )
    // Trailing-tip coordinates are implicit in `addArc`'s endAngle below;
    // we don't need the explicit point.

    path.move(to: leadingHub)

    // Leading edge: curves outward and away from the +x axis, giving the
    // blade its swept look.
    path.addCurve(
        to: leadingTip,
        control1: CGPoint(x: outerRadius * 0.35, y: hubRadius * 1.6),
        control2: CGPoint(x: outerRadius * 0.85, y: outerRadius * 0.45)
    )

    // Outer rim: short arc connecting leading tip to trailing tip,
    // following the outer radius.
    path.addArc(
        center: .zero,
        radius: outerRadius,
        startAngle: outerTopAngle,
        endAngle: outerBottomAngle,
        clockwise: true
    )

    // Trailing edge: mirrored sweep back to the hub.
    path.addCurve(
        to: trailingHub,
        control1: CGPoint(x: outerRadius * 0.85, y: -outerRadius * 0.45),
        control2: CGPoint(x: outerRadius * 0.35, y: -hubRadius * 1.6)
    )

    path.closeSubpath()
    return path
}

// MARK: - Write outputs

// Recreate the iconset directory each run so stale files don't survive.
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(
    at: iconsetDir, withIntermediateDirectories: true
)

for (pointSize, scale) in sizes {
    let pixelSize = pointSize * scale
    let suffix = scale == 1 ? "" : "@2x"
    let filename = "icon_\(pointSize)x\(pointSize)\(suffix).png"
    let data = renderIcon(pixelSize: pixelSize)
    try data.write(to: iconsetDir.appendingPathComponent(filename))
    print("→ wrote \(filename) (\(pixelSize)×\(pixelSize))")
}

// Pack the .iconset into a single .icns via Apple's iconutil. Output
// lands next to the iconset; build.sh copies it into the app bundle.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    iconsetDir.path,
    "-o", icnsPath.path
]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("✓ built \(icnsPath.lastPathComponent)")
