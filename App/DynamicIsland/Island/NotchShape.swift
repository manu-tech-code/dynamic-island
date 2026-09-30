import SwiftUI

/// The island outline: a flat top flush with the screen edge, small concave
/// shoulders where it meets the bezel, straight sides and rounded bottom
/// corners. The shape's rect includes one `shoulder` on each side of the body.
nonisolated struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat = 6

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = shoulder, w = rect.width, h = rect.height, k: CGFloat = 0.5523
        let r = max(0, min(bottomRadius, h - s, (w - 2 * s) / 2))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addCurve(to: CGPoint(x: w - s, y: s), control1: CGPoint(x: w - s * 0.45, y: 0), control2: CGPoint(x: w - s, y: s * 0.55))
        p.addLine(to: CGPoint(x: w - s, y: h - r))
        p.addCurve(to: CGPoint(x: w - s - r, y: h), control1: CGPoint(x: w - s, y: h - r + r * k), control2: CGPoint(x: w - s - r + r * k, y: h))
        p.addLine(to: CGPoint(x: s + r, y: h))
        p.addCurve(to: CGPoint(x: s, y: h - r), control1: CGPoint(x: s + r - r * k, y: h), control2: CGPoint(x: s, y: h - r + r * k))
        p.addLine(to: CGPoint(x: s, y: s))
        p.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: s, y: s * 0.55), control2: CGPoint(x: s * 0.45, y: 0))
        p.closeSubpath()
        return p
    }
}
