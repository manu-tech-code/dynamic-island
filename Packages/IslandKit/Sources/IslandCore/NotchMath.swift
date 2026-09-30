import CoreGraphics

public struct NotchRect: Equatable, Sendable {
    /// Camera housing (or virtual notch) in global screen coordinates, y up.
    public var rect: CGRect
    public var isHardware: Bool

    public init(rect: CGRect, isHardware: Bool) {
        self.rect = rect
        self.isHardware = isHardware
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
        let h = menuBar >= 20 ? min(menuBar, 40) : 32
        return NotchRect(rect: CGRect(x: f.midX - virtualWidth / 2, y: f.maxY - h, width: virtualWidth, height: h),
                         isHardware: false)
    }
}
