import AppKit
import QuartzCore
import SwiftUI

// Things that keep moving on the island, run by Core Animation in the render
// server: the app does no work per frame (the waveform following the music
// only sets five bars' heights, 30 times a second). A SwiftUI animation or an SF Symbols
// effect redraws the whole island every frame instead (its glass and the
// bubbles' blur too), which kept the CPU near 40% while music played.

/// The frame rate continuous motion is capped at: smooth enough for bars and
/// a spinning record, and a quarter of what ProMotion would otherwise draw.
private let motionFrameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)

/// The playing waveform. Its bars follow the music, bass on the left, treble
/// on the right (Settings › Now Playing › Waveform follows the music); without
/// that, or until the tap hears anything, they rise and fall on their own.
/// Still when paused, with Reduce Motion, or where it can't be seen (`animates` off).
struct Waveform: View {
    let playing: Bool
    let color: Color
    /// The tallest bar.
    var height: CGFloat = 13
    /// Off while it's out of sight (tucked under the notch): it stays still.
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let follows = env.settings.settings.nowPlaying.waveformFollowsAudio
        WaveformBars(moving: playing && animates && !reduceMotion, color: color.resolve(in: environment).cgColor, height: height,
                     levels: follows ? env.audioLevels : nil)
            .frame(width: WaveformBars.width(height: height), height: height)
            .opacity(playing ? 1 : 0.45)
            .accessibilityHidden(true)
    }
}

private struct WaveformBars: NSViewRepresentable {
    let moving: Bool
    let color: CGColor
    let height: CGFloat
    let levels: AudioLevelService?

    /// Each bar's resting height (of the tallest) and, on their own, how long it takes to fall.
    static let profile: [CGFloat] = [0.45, 0.8, 1, 0.6, 0.85]
    static let periods: [CFTimeInterval] = [0.82, 0.68, 0.95, 0.74, 0.88]
    static func barWidth(_ h: CGFloat) -> CGFloat { max(2, h * 0.18) }
    static func gap(_ h: CGFloat) -> CGFloat { max(1.5, h * 0.13) }
    static func width(height h: CGFloat) -> CGFloat {
        CGFloat(profile.count) * barWidth(h) + CGFloat(profile.count - 1) * gap(h)
    }

    func makeNSView(context: Context) -> WaveformLayerView { WaveformLayerView() }

    func updateNSView(_ view: WaveformLayerView, context: Context) {
        view.configure(moving: moving, color: color, height: height, levels: levels)
    }

    static func dismantleNSView(_ view: WaveformLayerView, coordinator: ()) {
        view.configure(moving: false, color: .clear, height: 0, levels: nil)
    }
}

final class WaveformLayerView: NSView {
    private var bars: [CALayer] = []
    private var barHeight: CGFloat = 0
    private var moving = false
    private var levels: AudioLevelService?
    /// While following the music: the service listening, and a 30 fps tick reading it.
    private var listening: AudioLevelService?
    private var link: CADisplayLink?
    /// The bars' own rise and fall is running.
    private var onTheirOwn = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bars = WaveformBars.profile.map { _ in CALayer() }
        bars.forEach { layer?.addSublayer($0) }
        rest()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks go to the island underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(moving: Bool, color: CGColor, height: CGFloat, levels: AudioLevelService?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color }
        CATransaction.commit()
        if height != barHeight {
            barHeight = height
            needsLayout = true
        }
        guard moving != self.moving || levels !== self.levels else { return }
        self.moving = moving
        self.levels = levels
        update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = WaveformBars.barWidth(barHeight), gap = WaveformBars.gap(barHeight)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: w, height: barHeight)
            bar.position = CGPoint(x: CGFloat(i) * (w + gap) + w / 2, y: bounds.midY)
            bar.cornerRadius = w / 2
        }
        CATransaction.commit()
    }

    private func update() {
        let follows = moving && levels != nil && window != nil
        if follows, listening == nil, let levels {
            levels.acquire()
            listening = levels
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = motionFrameRate
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !follows, let listening {
            link?.invalidate()
            link = nil
            listening.release()
            self.listening = nil
        }
        // On their own until the tap hears something (`tick` takes over), or when not following.
        if moving, !onTheirOwn { riseAndFall() }
        if !moving { stopOnTheirOwn(); rest() }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let listening else { return }
        let heard = listening.levels.snapshot()
        guard heard.hearing else {
            if !onTheirOwn { riseAndFall() }
            return
        }
        if onTheirOwn { stopOnTheirOwn() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let level = CGFloat(i < heard.bands.count ? heard.bands[i] : 0)
            bar.transform = CATransform3DMakeScale(1, 0.18 + 0.82 * level, 1)
        }
        CATransaction.commit()
    }

    /// The waveform's shape, still.
    private func rest() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() { bar.transform = CATransform3DMakeScale(1, WaveformBars.profile[i], 1) }
        CATransaction.commit()
    }

    private func riseAndFall() {
        rest()
        for (i, bar) in bars.enumerated() {
            let fall = CABasicAnimation(keyPath: "transform.scale.y")
            fall.fromValue = WaveformBars.profile[i]
            fall.toValue = WaveformBars.profile[i] * 0.35
            fall.duration = WaveformBars.periods[i]
            fall.autoreverses = true
            fall.repeatCount = .infinity
            fall.timeOffset = Double(i) * 0.23   // out of step with each other
            fall.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fall.preferredFrameRateRange = motionFrameRate
            bar.add(fall, forKey: "wave")
        }
        onTheirOwn = true
    }

    private func stopOnTheirOwn() {
        bars.forEach { $0.removeAnimation(forKey: "wave") }
        onTheirOwn = false
    }
}

/// A picture Core Animation keeps moving: the record's spin, the glow's pulse.
/// The picture itself is drawn once, by SwiftUI (see `LayerPicture.render`).
struct LayerAnimatedImage: NSViewRepresentable {
    enum Motion: Equatable {
        /// One turn every `period` seconds, clockwise.
        case spin(period: Double)
        /// Fades and narrows to `opacity` and `scaleX`, and back, every 2 × `period`.
        case pulse(period: Double, opacity: Float, scaleX: CGFloat)
    }

    let image: CGImage?
    let motion: Motion
    let moving: Bool

    func makeNSView(context: Context) -> AnimatedImageView { AnimatedImageView() }

    func updateNSView(_ view: AnimatedImageView, context: Context) {
        view.configure(image: image, motion: motion, moving: moving)
    }
}

final class AnimatedImageView: NSView {
    private let picture = CALayer()
    private var motion: LayerAnimatedImage.Motion?
    private var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        picture.contentsGravity = .resizeAspect
        layer?.addSublayer(picture)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(image: CGImage?, motion: LayerAnimatedImage.Motion, moving: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        picture.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        guard motion != self.motion || moving != self.moving else { return }
        self.motion = motion
        self.moving = moving
        picture.removeAnimation(forKey: "motion")
        if moving { picture.add(Self.animation(motion), forKey: "motion") }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = bounds
        CATransaction.commit()
    }

    private static func animation(_ motion: LayerAnimatedImage.Motion) -> CAAnimation {
        let animation: CAAnimation
        switch motion {
        case .spin(let period):
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = period
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            animation = spin
        case .pulse(let period, let opacity, let scaleX):
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = opacity
            let narrow = CABasicAnimation(keyPath: "transform.scale.x")
            narrow.fromValue = 1
            narrow.toValue = scaleX
            let pulse = CAAnimationGroup()
            pulse.animations = [fade, narrow]
            pulse.duration = period
            pulse.autoreverses = true
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation = pulse
        }
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = motionFrameRate
        return animation
    }
}

enum LayerPicture {
    /// Draws a SwiftUI view once, at Retina scale, for a layer to move around.
    static func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.cgImage
    }
}
