import IslandCore
import SwiftUI

/// Every timing the island's shape and content move with, in one place so
/// they stay in the same family. Unhurried springs with little bounce read as
/// fluid; short ones read as snappy.
enum IslandMotion {
    /// Opening a state (expanded, dashboard, shelf).
    static let open = Animation.spring(duration: 0.62, bounce: 0.2)
    /// Closing back to compact or idle: no overshoot.
    static let close = Animation.spring(duration: 0.55, bounce: 0.02)
    /// Size changes the engine makes (an activity starts or ends).
    static let engine = Animation.spring(duration: 0.55, bounce: 0.14)

    /// The title dropping down under the compact island, and going back up.
    static let peekOpen = Animation.spring(duration: 0.6, bounce: 0.16)
    static let peekClose = Animation.spring(duration: 0.5, bounce: 0)
    /// The title row's fade as it leaves (it rides the shape's spring coming in).
    static let peekRowOut = Animation.easeOut(duration: 0.25)

    /// Hover state changes (the virtual notch showing on displays without one).
    static let hover = Animation.easeInOut(duration: 0.3)

    /// Content swapping between states: out quickly, in once the shape is moving.
    static let contentIn = Animation.easeOut(duration: 0.4).delay(0.1)
    static let contentOut = Animation.easeIn(duration: 0.2)

    /// The hover bounce: a gentle swell, then a slow springy settle.
    static let bounceUp = Spring(duration: 0.2, bounce: 0)
    static let bounceUpDuration: TimeInterval = 0.2
    static let bounceSettle = Spring(duration: 0.8, bounce: 0.35)
    static let bounceSettleDuration: TimeInterval = 0.8

    /// With Reduce Motion: a plain short fade instead of any spring.
    static let reduced = Animation.easeInOut(duration: 0.25)

    // MARK: hover to show (the prototypes' timings)

    /// The shape coming out from under the notch, or tucking back in.
    static func revealShape(_ style: RevealStyle, opening: Bool) -> Animation {
        switch (style, opening) {
        case (.slide, true): .spring(duration: 0.62, bounce: 0.2)
        case (.slide, false): .spring(duration: 0.55, bounce: 0.02)
        case (.ink, true): .spring(duration: 0.6, bounce: 0.15)
        case (.ink, false): .spring(duration: 0.5, bounce: 0).delay(0.07)   // after the content has gone
        case (.elastic, true): .spring(duration: 0.7, bounce: 0.42)
        case (.elastic, false): .spring(duration: 0.45, bounce: 0)
        case (.curtain, true): .spring(duration: 0.6, bounce: 0.18)         // the left side, first
        case (.curtain, false): .spring(duration: 0.5, bounce: 0.02).delay(0.08) // the left side, last
        }
    }

    /// The content's own motion, for styles where it doesn't just ride the edges.
    static func revealContent(_ style: RevealStyle, opening: Bool) -> Animation? {
        switch (style, opening) {
        case (.ink, true): .easeOut(duration: 0.28).delay(0.12)   // once the edges have passed it
        case (.ink, false): .easeIn(duration: 0.12)
        case (.elastic, true): .spring(duration: 0.6, bounce: 0.35).delay(0.04)
        case (.elastic, false): .spring(duration: 0.45, bounce: 0)
        case (.slide, _), (.curtain, _): nil
        }
    }

    /// The curtain's right side: out 110 ms after the left, in 80 ms before it.
    static func curtainTrailing(opening: Bool) -> Animation {
        opening ? .spring(duration: 0.6, bounce: 0.18).delay(0.11) : .spring(duration: 0.5, bounce: 0.02)
    }

    // MARK: while music plays (the prototypes' timings)

    /// A bubble or the drop pulled out of the notch, a beat after the island
    /// has gone back past it, with a springy settle; the drop falls slower.
    static func dropletOut(_ style: PlayingStyle) -> Animation {
        style == .drip ? .spring(duration: 0.95, bounce: 0.5).delay(0.16) : .spring(duration: 0.7, bounce: 0.35).delay(0.14)
    }
    /// Back into the notch as the island comes out over it.
    static let dropletIn = Animation.spring(duration: 0.45, bounce: 0)
    /// The record rolling out from behind the notch.
    static let recordOut = Animation.spring(duration: 0.8, bounce: 0.3).delay(0.12)
    /// What's inside a bubble: in once the bubble is out, out at once.
    static let indicatorContentIn = Animation.easeOut(duration: 0.22).delay(0.2)
    static let indicatorContentOut = Animation.easeIn(duration: 0.1)
    /// The underglow coming up once the island has tucked in, and going.
    static let glowIn = Animation.easeOut(duration: 0.45).delay(0.2)
    static let glowOut = Animation.easeIn(duration: 0.14)
}

/// Gives an animatable change its own animation when there is one, and leaves
/// it to the surrounding transaction otherwise (`.animation(nil)` would stop it).
struct OptionalAnimation<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        if let animation { content.animation(animation, value: value) } else { content }
    }
}
