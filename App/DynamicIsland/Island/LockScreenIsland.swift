import AppKit
import IslandCore
import SwiftUI

/// The lock opening on the island when the Mac unlocks. It's ready (in its own
/// display-only panel, under the lock screen like every app window) while the
/// Mac is locked; once the lock screen fades away, the closed lock opens, holds
/// a beat, and goes back into the notch before the real island returns.
final class LockScreenIsland {
    @Observable
    final class State {
        enum Phase { case hidden, locked, unlocked }
        var phase: Phase = .hidden
        var notch: NotchRect
        init(notch: NotchRect) { self.notch = notch }
    }

    static let panelSize = CGSize(width: 420, height: 90)

    let state: State
    /// Called once the unlock animation is over, so the real island can come back.
    var onFinished: () -> Void = {}
    private let panel: NSPanel
    private var task: Task<Void, Never>?

    init(notch: NotchRect) {
        state = State(notch: notch)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: LockIslandView(state: state))
        host.sizingOptions = []
        panel.contentView = host
    }

    func update(notch: NotchRect, screenTop: CGFloat) {
        state.notch = notch
        let s = Self.panelSize
        panel.setFrame(CGRect(x: notch.rect.midX - s.width / 2, y: screenTop - s.height, width: s.width, height: s.height), display: true)
    }

    var isShowing: Bool { state.phase != .hidden }

    func setLocked(_ locked: Bool, reduceMotion: Bool) {
        task?.cancel()
        if locked {
            panel.orderFrontRegardless()
            var t = Transaction()
            t.disablesAnimations = true // nobody sees it under the lock screen
            withTransaction(t) { state.phase = .locked }
            return
        }
        guard state.phase == .locked else { return }
        // Unlocked: once the lock screen has faded, the closed lock opens, holds
        // a beat, then the island goes back into the notch.
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            withAnimation(reduceMotion ? IslandMotion.reduced : .spring(duration: 0.45, bounce: 0.25)) { self.state.phase = .unlocked }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? IslandMotion.reduced : IslandMotion.close) { self.state.phase = .hidden }
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
            self.onFinished()
        }
    }

    func close() {
        task?.cancel()
        panel.orderOut(nil)
    }
}

/// Black, like the notch: the lock screen's wallpaper is behind it, not the desktop.
private struct LockIslandView: View {
    let state: LockScreenIsland.State

    var body: some View {
        let notch = state.notch.rect.size
        let shown = state.phase != .hidden
        let size = shown ? IslandMetrics.lockSize(notch: notch) : IslandMetrics.idleSize(notch: notch)
        ZStack(alignment: .topLeading) {
            NotchShape(bottomRadius: IslandMetrics.radius(forHeight: size.height), shoulder: IslandMetrics.shoulder)
                .fill(.black)
            if shown {
                Image(systemName: state.phase == .unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: IslandMetrics.glyph, height: size.height)
                    .padding(.leading, IslandMetrics.shoulder + IslandMetrics.earOuterPadding)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width + 2 * IslandMetrics.shoulder, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }
}
