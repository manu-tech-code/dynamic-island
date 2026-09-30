import AppKit

/// Where the camera housing is on a screen, in global screen coordinates (y up).
struct NotchGeometry {
    let screen: NSScreen
    let rect: CGRect
    let isHardware: Bool
    let menuBarHeight: CGFloat

    static let virtualWidth: CGFloat = 185

    init(screen: NSScreen) {
        self.screen = screen
        let f = screen.frame
        menuBarHeight = f.maxY - screen.visibleFrame.maxY
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            isHardware = true
            let h = screen.safeAreaInsets.top
            rect = CGRect(x: l.maxX, y: f.maxY - h, width: r.minX - l.maxX, height: h)
        } else {
            isHardware = false
            let h = menuBarHeight > 0 ? menuBarHeight : 32
            rect = CGRect(x: f.midX - Self.virtualWidth / 2, y: f.maxY - h, width: Self.virtualWidth, height: h)
        }
    }

    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    static func describeAllScreens() -> String {
        NSScreen.screens.enumerated().map { i, s in
            let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "?"
            return """
            screen[\(i)] "\(s.localizedName)" id=\(id) scale=\(s.backingScaleFactor)
                frame=\(s.frame) visible=\(s.visibleFrame)
                safeAreaInsets=top \(s.safeAreaInsets.top) left \(s.safeAreaInsets.left) right \(s.safeAreaInsets.right)
                auxTopLeft=\(s.auxiliaryTopLeftArea.map { "\($0)" } ?? "nil") auxTopRight=\(s.auxiliaryTopRightArea.map { "\($0)" } ?? "nil")
            """
        }.joined(separator: "\n")
    }
}
