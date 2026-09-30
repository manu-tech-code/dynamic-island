import IslandCore
import SwiftUI

/// Fills the island panel. Draws the island at the top centre: optional
/// artwork glow, the surface (black, glass, or the Hybrid collar over glass)
/// and the content for the current presentation.
struct IslandRootView: View {
    let model: IslandViewModel
    /// The panel's coordinate space (top-left origin), for pointer tests.
    static let space = "island"

    var body: some View {
        let size = model.outerSize
        let shape = NotchShape(bottomRadius: model.radius, shoulder: IslandMetrics.shoulder)

        ZStack(alignment: .top) {
            island(size: size, shape: shape)
                // The pointer arriving on the closed island: one springy bounce, no resize.
                .keyframeAnimator(initialValue: Bounce(), trigger: model.bounce) { content, b in
                    content.scaleEffect(x: b.x, y: b.y, anchor: .top)
                } keyframes: { _ in
                    KeyframeTrack(\.x) {
                        SpringKeyframe(1.025, duration: 0.11, spring: .snappy)
                        SpringKeyframe(1, duration: 0.55, spring: .bouncy(duration: 0.55, extraBounce: 0.15))
                    }
                    KeyframeTrack(\.y) {
                        SpringKeyframe(1.1, duration: 0.11, spring: .snappy)
                        SpringKeyframe(1, duration: 0.55, spring: .bouncy(duration: 0.55, extraBounce: 0.15))
                    }
                }

            if !model.notch.isHardware, model.settings.virtualNotchWhenIdle || model.presentation != .idle || model.hover {
                // Displays without a camera housing get a virtual one.
                NotchShape(bottomRadius: 10, shoulder: IslandMetrics.shoulder)
                    .fill(.black)
                    .frame(width: model.notch.rect.width + 2 * IslandMetrics.shoulder, height: model.notch.rect.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named(Self.space))
        .transaction(value: model.outerSize) { t in
            // Changes the engine makes (an activity starts or ends) get a gentle spring;
            // user actions bring their own animation.
            if t.animation == nil, !t.disablesAnimations, !model.reduceMotion { t.animation = .spring(duration: 0.45, bounce: 0.15) }
        }
        .environment(\.colorScheme, model.material == .black ? .dark : colorSchemeFromSystem)
    }

    /// The glow and the island itself: the part that bounces.
    private func island(size: CGSize, shape: NotchShape) -> some View {
        ZStack(alignment: .top) {
            ZStack {
                if let glow = model.glowColor {
                    shape.fill(glow)
                        .frame(width: size.width, height: size.height)
                        .blur(radius: 22)
                        .opacity(0.55)
                        .offset(y: 6)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            // Only the glow: it fades in and out and eases between artwork colours.
            .animation(model.reduceMotion ? nil : .easeInOut(duration: 0.5), value: model.glowColor)

            IslandContent(model: model)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(alignment: .top) { surfaceBackground(shape: shape, size: size) }
                .modifier(GlassSurface(material: model.material, shape: shape))
                .clipShape(shape)
                .shadow(color: .black.opacity(model.material == .black ? 0.3 : 0), radius: 10, y: 4)
                .contentShape(shape)
                .onTapGesture { model.tap() }
                // Anything dropped on the island, in any state, goes to the shelf.
                .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: Binding(
                    get: { model.dropTargeted }, set: { model.setDropTargeted($0) })) { providers in
                    guard !model.isPreview, model.settings[module: .shelf].enabled else { return false }
                    let ok = model.env.shelf.accept(providers: providers)
                    if ok { model.didDrop() }
                    return ok
                }
                .overlay {
                    if model.dropTargeted {
                        shape.stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                    } else if model.env.look.increaseContrast, model.material != .glass {
                        // Increase Contrast: a clear edge on the parts we draw ourselves.
                        shape.stroke(Color.white.opacity(0.85), lineWidth: 1).allowsHitTesting(false)
                    }
                }
                .overlay {
                    if model.resizeBase != nil, !model.isPreview { ResizeHandles(model: model) }
                }
        }
    }

    @Environment(\.colorScheme) private var colorSchemeFromSystem

    @ViewBuilder
    private func surfaceBackground(shape: NotchShape, size: CGSize) -> some View {
        switch model.material {
        case .black:
            shape.fill(.black)
        case .hybrid:
            // Sized in points, not as gradient stops relative to the height:
            // stops were computed for the final height, so while the island
            // grew the collar shrank, and while it shrank the whole island
            // flashed black. Frames animate with the shape instead.
            VStack(spacing: 0) {
                Rectangle().fill(.black).frame(height: model.collarHeight)
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: model.env.look.collarFade(open: model.isOpen))
                Spacer(minLength: 0)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        case .glass:
            Color.clear
        }
    }
}

/// Real system Liquid Glass behind the content, so the user's slider,
/// Reduce Transparency and Increase Contrast all apply without any work here.
private struct GlassSurface: ViewModifier {
    let material: IslandMaterial
    let shape: NotchShape

    func body(content: Content) -> some View {
        switch material {
        case .black: content
        case .hybrid, .glass: content.glassEffect(.regular, in: shape)
        }
    }
}

/// Swaps content per presentation with Apple's "grow into content" feel:
/// the shape moves first, content fades and sharpens in 70 ms later.
struct IslandContent: View {
    let model: IslandViewModel

    var body: some View {
        ZStack(alignment: .top) {
            content
                .id(model.contentKey)
                .transition(model.reduceMotion ? .opacity : .islandContent)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.presentation {
        case .idle:
            Color.clear
        case .compact:
            CompactView(model: model)
        case .expanded(let id):
            if let activity = model.env.engine.activity(id: id) {
                ExpandedView(activity: activity, model: model)
            }
        case .dashboard:
            DashboardView(model: model)
        case .shelf:
            ShelfView(model: model)
        case .alert(let alert):
            AlertView(alert: alert, model: model)
        }
    }
}

/// Invisible strips on the open island's left and right edges. Dragging one
/// changes the width on both sides (the island stays centred).
private struct ResizeHandles: View {
    let model: IslandViewModel
    @State private var start: Double?

    var body: some View {
        HStack(spacing: 0) {
            handle(direction: -1)
            Spacer(minLength: 0)
            handle(direction: 1)
        }
        .padding(.horizontal, IslandMetrics.shoulder - 2)
        // Open: below the ear row, so its buttons stay clickable. Compact: full height.
        .padding(.top, model.isOpen ? model.notch.rect.height : 0)
    }

    private func handle(direction: CGFloat) -> some View {
        Color.clear
            .frame(width: model.isOpen ? 10 : 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if start == nil { start = model.widthScale }
                        model.resize(by: value.translation.width * direction, from: start ?? 1)
                        NSCursor.resizeLeftRight.set()
                    }
                    .onEnded { _ in
                        model.endResize()
                        start = nil
                    }
            )
            .help("Drag to change the width")
            .accessibilityHidden(true)
    }
}

/// Horizontal and vertical scale of the hover bounce.
private struct Bounce {
    var x: CGFloat = 1
    var y: CGFloat = 1
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: ContentAppear(progress: 0), identity: ContentAppear(progress: 1))
                .animation(.easeOut(duration: 0.28).delay(0.07)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }
}

private struct ContentAppear: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.96 + 0.04 * progress, anchor: .top)
            .blur(radius: 6 * (1 - progress))
    }
}
