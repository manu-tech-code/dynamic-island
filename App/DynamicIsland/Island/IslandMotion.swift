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

    /// The dashboard button fading in its room on hover.
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
}
