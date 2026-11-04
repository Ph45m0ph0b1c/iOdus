import AppKit
import SwiftUI

/// The iOdus app icon: a white controller on a green glow, on a dark green
/// tile. The controller is an own drawing (SF Symbols must not be used in app
/// icons). It follows the macOS icon grid: an 824 pt tile on a 1024 pt canvas.
struct AppIconView: View {
    static let green = Color(red: 0.06, green: 0.49, blue: 0.06)
    static let bright = Color(red: 0.36, green: 0.85, blue: 0.30)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.30, blue: 0.10), Color(red: 0.02, green: 0.16, blue: 0.04)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .fill(RadialGradient(colors: [Self.bright.opacity(0.85), Self.green.opacity(0.35), .clear],
                                     center: .center, startRadius: 10, endRadius: 330))
                .frame(width: 660, height: 660)
                .offset(y: 30)
            ControllerGlyph()
                .fill(LinearGradient(colors: [.white, Color(white: 0.85)], startPoint: .top, endPoint: .bottom),
                      style: FillStyle(eoFill: true))
                .frame(width: 620, height: 397)
                .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
                .offset(y: 25)
            // A light reflection on the top of the glass tile.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 900, height: 420)
                .offset(y: -330)
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 3)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        .frame(width: 1024, height: 1024)
    }

    /// The icon as an image of `size` pixels.
    @MainActor
    static func image(size: CGFloat = 1024) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconView().scaleEffect(size / 1024).frame(width: size, height: size))
        renderer.scale = 1
        return renderer.nsImage
    }

    /// Writes the PNG files of a macOS .iconset (16 ... 512 @1x and @2x) into `folder`.
    /// `iconutil -c icns <folder>` then makes AppIcon.icns.
    @MainActor
    static func writeIconset(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let image = image(size: CGFloat(points * scale)), let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    throw BackendError.failed("Could not draw the icon at \(points)@\(scale)x.")
                }
                try png.write(to: folder.appendingPathComponent(name))
            }
        }
    }
}

/// A generic game controller. The D-pad and the buttons are holes (even-odd
/// fill), so the glow behind the controller shows through them.
struct ControllerGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn in a 1000 x 640 box, then scaled to `rect`.
        let sx = rect.width / 1000, sy = rect.height / 640
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        // The body with two grips.
        path.move(to: p(300, 70))
        path.addLine(to: p(700, 70))
        path.addCurve(to: p(880, 150), control1: p(800, 70), control2: p(855, 95))
        path.addCurve(to: p(990, 520), control1: p(940, 290), control2: p(990, 420))
        path.addCurve(to: p(855, 615), control1: p(990, 590), control2: p(920, 625))
        path.addCurve(to: p(690, 470), control1: p(790, 605), control2: p(745, 470))
        path.addLine(to: p(310, 470))
        path.addCurve(to: p(145, 615), control1: p(255, 470), control2: p(210, 605))
        path.addCurve(to: p(10, 520), control1: p(80, 625), control2: p(10, 590))
        path.addCurve(to: p(120, 150), control1: p(10, 420), control2: p(60, 290))
        path.addCurve(to: p(300, 70), control1: p(145, 95), control2: p(200, 70))
        path.closeSubpath()

        // The D-pad as one plus outline, so that the even-odd fill makes one hole.
        let cx: CGFloat = 285, cy: CGFloat = 265, arm: CGFloat = 105, half: CGFloat = 38
        path.move(to: p(cx - half, cy - arm))
        for (x, y) in [(cx + half, cy - arm), (cx + half, cy - half), (cx + arm, cy - half), (cx + arm, cy + half),
                       (cx + half, cy + half), (cx + half, cy + arm), (cx - half, cy + arm), (cx - half, cy + half),
                       (cx - arm, cy + half), (cx - arm, cy - half), (cx - half, cy - half)] {
            path.addLine(to: p(x, y))
        }
        path.closeSubpath()

        // Four face buttons in a diamond.
        let bx: CGFloat = 715, by: CGFloat = 265, gap: CGFloat = 74, r: CGFloat = 38
        for (dx, dy) in [(0.0, -1.0), (1.0, 0.0), (0.0, 1.0), (-1.0, 0.0)] {
            let center = p(bx + dx * gap, by + dy * gap)
            path.addEllipse(in: CGRect(x: center.x - r * sx, y: center.y - r * sy, width: r * 2 * sx, height: r * 2 * sy))
        }
        return path
    }
}
