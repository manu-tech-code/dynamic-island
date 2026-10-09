import CoreGraphics

public struct NotchRect: Equatable, Sendable {
    /// Camera housing (or virtual notch) in global screen coordinates, y up.
    public var rect: CGRect
    public var isHardware: Bool
    /// The display's menu bar hides until the pointer reaches it, so a
    /// virtual notch would sit over windows instead of in the menu bar.
    public var menuBarHidden: Bool

    public init(rect: CGRect, isHardware: Bool, menuBarHidden: Bool = false) {
        self.rect = rect
        self.isHardware = isHardware
        self.menuBarHidden = menuBarHidden
    }

    /// Whether the black virtual notch is drawn (never on a real one): while
    /// the island shows something; while it's idle, only when asked for and
    /// the menu bar is there to hold it.
    public func drawsVirtualNotch(idle: Bool, whenIdle: Bool) -> Bool {
        guard !isHardware else { return false }
        return !idle || (whenIdle && !menuBarHidden)
    }
}

public enum NotchMath {
    public static let virtualWidth: CGFloat = 185

    /// Computes the notch from the values `NSScreen` reports. A screen has a
    /// hardware notch when it reports a top safe-area inset and both auxiliary
    /// top areas; otherwise a virtual notch is centred under the menu bar.
    public static func notch(screenFrame f: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                             auxiliaryTopLeft l: CGRect?, auxiliaryTopRight r: CGRect?) -> NotchRect {
        if safeAreaTop > 0, let l, let r, r.minX > l.maxX {
            return NotchRect(rect: CGRect(x: l.maxX, y: f.maxY - safeAreaTop, width: r.minX - l.maxX, height: safeAreaTop),
                             isHardware: true)
        }
        let menuBar = f.maxY - visibleFrame.maxY
        // An auto-hidden menu bar leaves no room at the top: the island still
        // needs a height to hang from, but nothing should stay drawn there.
        let hidden = menuBar < 20
        let h = hidden ? 32 : min(menuBar, 40)
        return NotchRect(rect: CGRect(x: f.midX - virtualWidth / 2, y: f.maxY - h, width: virtualWidth, height: h),
                         isHardware: false, menuBarHidden: hidden)
    }
}
