import SwiftUI

enum IslandMaterial: String, CaseIterable { case hybrid = "Hybrid", glass = "Glass", black = "Black" }
enum GlassVariant: String, CaseIterable { case regular = "Regular", clear = "Clear" }
/// Where compact content goes: in "ears" beside the notch (covers menu bar
/// items next to it) or in a band hanging below the notch (covers nothing).
enum CompactStyle: String, CaseIterable { case ears = "Beside the notch", below = "Below the notch" }

final class IslandModel: ObservableObject {
    @Published var expanded = false
    @Published var hover = false
    @Published var material: IslandMaterial = .hybrid
    @Published var variant: GlassVariant = .regular
    @Published var compactStyle: CompactStyle = .ears
    @Published var clicks = 0
    var notchSize = CGSize(width: 185, height: 32)
    var toggleLab: () -> Void = {}
    var runFullScreenTest: () -> Void = {}
    var quit: () -> Void = {}
    let shoulder: CGFloat = 6

    /// Body size (without shoulders).
    static let belowBand: CGFloat = 28

    var bodySize: CGSize {
        var s: CGSize
        if expanded { s = CGSize(width: 520, height: 188) }
        else if compactStyle == .ears { s = CGSize(width: notchSize.width + 2 * 54, height: notchSize.height) }
        else { s = CGSize(width: notchSize.width + 2 * 12, height: notchSize.height + Self.belowBand) }
        if hover { s.width += expanded ? 4 : 12; s.height += expanded ? 2 : 4 }
        return s
    }
    var outerSize: CGSize { CGSize(width: bodySize.width + 2 * shoulder, height: bodySize.height) }
    var radius: CGFloat { expanded ? 34 : (compactStyle == .below ? 18 : (hover ? 14 : 12)) }
    /// How far below the notch the black collar takes to fade into glass.
    var collarFade: CGFloat { expanded ? 18 : 8 }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var look: SystemLook

    var body: some View {
        let size = model.outerSize
        let shape = NotchShape(bottomRadius: model.radius, shoulder: model.shoulder)
        ZStack(alignment: .top) {
            surface(shape: shape)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) { collar(size: size).clipShape(shape) }
                .overlay(alignment: .top) { content.frame(width: size.width, height: size.height, alignment: .top).clipShape(shape) }
                .contentShape(shape)
                .onTapGesture {
                    model.clicks += 1
                    Log.write("CLICK #\(model.clicks) on island (expanded → \(!model.expanded)) frontApp=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                    model.expanded.toggle()
                }
                .contextMenu {
                    Button(model.expanded ? "Collapse" : "Expand") { model.expanded.toggle() }
                    Picker("Material", selection: $model.material) {
                        ForEach(IslandMaterial.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Glass", selection: $model.variant) {
                        ForEach(GlassVariant.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Compact style", selection: $model.compactStyle) {
                        ForEach(CompactStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Button("Show / hide glass lab") { model.toggleLab() }
                    Button("Run full-screen test") { model.runFullScreenTest() }
                    Divider()
                    Button("Quit spike") { model.quit() }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(look.reduceMotion ? .easeInOut(duration: 0.2)
                   : .spring(duration: model.expanded ? 0.5 : 0.42, bounce: model.expanded ? 0.22 : 0.06),
                   value: model.expanded)
        .animation(look.reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: model.hover)
        .animation(look.reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.18), value: model.compactStyle)
    }

    @ViewBuilder private func surface(shape: NotchShape) -> some View {
        switch model.material {
        case .black:
            shape.fill(.black)
        case .hybrid, .glass:
            Color.clear.glassEffect(model.variant == .regular ? .regular : .clear, in: shape)
        }
    }

    @ViewBuilder private func collar(size: CGSize) -> some View {
        if model.material == .hybrid {
            let h = max(size.height, 1)
            Rectangle().fill(.black)
                .frame(width: size.width, height: size.height)
                .mask(LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: min(1, model.notchSize.height / h)),
                    .init(color: .clear, location: min(1, (model.notchSize.height + model.collarFade) / h)),
                ], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
        }
    }

    private var earColor: Color { model.material == .glass ? .primary : .white }

    private var waveform: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, isActive: !look.reduceMotion)
            .foregroundStyle(.pink)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.expanded || model.compactStyle == .ears {
                HStack {
                    Image(systemName: "music.note").foregroundStyle(.pink)
                    if model.expanded { Text("Spike").font(.system(size: 12, weight: .semibold)).foregroundStyle(earColor) }
                    Spacer(minLength: model.notchSize.width)
                    waveform
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, model.shoulder + 14)
                .frame(height: model.notchSize.height)
            } else {
                // Below-the-notch compact: nothing beside the camera, content in a band under it.
                Color.clear.frame(height: model.notchSize.height)
                HStack(spacing: 6) {
                    Image(systemName: "music.note").foregroundStyle(.pink)
                    Text("Glass Hours").font(.system(size: 12, weight: .semibold)).lineLimit(1).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    waveform
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, model.shoulder + 14)
                .frame(height: IslandModel.belowBand - 2)
                .transition(.opacity)
            }

            if model.expanded {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.material.rawValue) · glassEffect(.\(model.variant.rawValue.lowercased())) in NotchShape")
                        .font(.system(size: 14, weight: .semibold))
                    Group {
                        Text("Appearance \(look.appearance) · accent \(look.accentHex)")
                        Text("Reduce transparency \(onOff(look.reduceTransparency)) · Increase contrast \(onOff(look.increaseContrast))")
                        Text("Reduce motion \(onOff(look.reduceMotion)) · glass tint \(look.glassTint) · clicks \(model.clicks)")
                        Text("Last change \(look.lastChange)")
                    }
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, model.shoulder + 18)
                .padding(.top, 14)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }

    private func onOff(_ b: Bool) -> String { b ? "ON" : "off" }
}
