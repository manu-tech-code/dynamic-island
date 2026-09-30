import AppKit
import SwiftUI

/// Six glass variants side by side. Shown twice: in a normal key window and in
/// a non-activating panel (never key), so we can see whether glass renders,
/// follows the Liquid Glass slider, and stays "active" when its window isn't key.
struct GlassLab: View {
    let title: String
    @ObservedObject var look: SystemLook
    var onClose: () -> Void = {}
    var onQuit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title).font(.headline)
                Spacer()
                Text("RT \(look.reduceTransparency ? "ON" : "off") · IC \(look.increaseContrast ? "ON" : "off") · \(look.appearance)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Button("Close lab", action: onClose).keyboardShortcut(.cancelAction)
                Button("Quit spike", action: onQuit)
            }
            ZStack {
                // Stripes behind the lower half of every tile: in-window content for the glass to refract.
                VStack(spacing: 0) {
                    Color.clear.frame(height: 190)
                    HStack(spacing: 0) {
                        ForEach([Color.red, .orange, .yellow, .green, .teal, .blue, .indigo, .purple, .pink], id: \.self) { $0 }
                    }
                    .frame(height: 70)
                    Color.clear.frame(height: 90)
                }
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        tile("A · SwiftUI .regular") { Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24)) }
                        tile("B · SwiftUI .clear") { Color.clear.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 24)) }
                        tile("C · SwiftUI .regular in NotchShape") { Color.clear.glassEffect(.regular, in: NotchShape(bottomRadius: 28)) }
                    }
                    GridRow {
                        tile("D · NSGlassEffectView regular") { AppKitGlass(style: .regular, notchMask: false) }
                        tile("E · NSGlassEffectView clear") { AppKitGlass(style: .clear, notchMask: false) }
                        tile("F · NSGlassEffectView + notch mask") { AppKitGlass(style: .regular, notchMask: true) }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 820, height: 400)
    }

    private func tile<G: View>(_ label: String, @ViewBuilder glass: () -> G) -> some View {
        ZStack {
            glass()
            VStack(spacing: 4) {
                Text(label).font(.system(size: 12, weight: .semibold))
                Text("primary").font(.system(size: 11)).foregroundStyle(.primary)
                Text("secondary").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 250, height: 150)
    }
}

struct AppKitGlass: NSViewRepresentable {
    var style: NSGlassEffectView.Style
    var notchMask: Bool

    func makeNSView(context: Context) -> MaskableGlassView {
        let v = MaskableGlassView()
        v.style = style
        v.cornerRadius = 24
        v.useNotchMask = notchMask
        return v
    }
    func updateNSView(_ v: MaskableGlassView, context: Context) {
        v.style = style
        v.useNotchMask = notchMask
    }
}

final class MaskableGlassView: NSGlassEffectView {
    var useNotchMask = false { didSet { needsLayout = true } }
    private var loggedMask = false
    override func layout() {
        super.layout()
        guard useNotchMask else { layer?.mask = nil; return }
        wantsLayer = true
        let m = CAShapeLayer()
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        m.path = NotchShape(bottomRadius: 28).path(in: bounds).cgPath.copy(using: &flip)
        layer?.mask = m
        if !loggedMask, bounds.width > 0 {
            loggedMask = true
            Log.write("TILE F mask set=\(layer?.mask != nil) layer=\(layer.map { String(describing: type(of: $0)) } ?? "nil") sublayers=\(layer?.sublayers?.count ?? 0) bounds=\(bounds)")
        }
    }
}
