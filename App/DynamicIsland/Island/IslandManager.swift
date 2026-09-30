import AppKit
import IslandCore
import Observation

/// Keeps one island per chosen display, rebuilt when displays change, and
/// routes mouse events to them. Global mouse-move monitoring needs no permission.
final class IslandManager {
    private let env: AppEnvironment
    private(set) var controllers: [CGDirectDisplayID: IslandController] = [:]
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    /// Drag pasteboard change count at the last mouse-down; a new count while
    /// dragging means a real drag with content (not a window move or selection).
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var dragOpenedShelf = false

    init(env: AppEnvironment) {
        self.env = env
    }

    func start() {
        rebuild()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        whenChanged({ [env] in env.settings.settings.displays }) { [weak self] _ in self?.rebuild() }
        whenChanged({ [env] in env.engine.live.map(\.id) }) { [weak self] _ in
            self?.controllers.values.forEach { $0.model.pruneIfStale() }
        }
        installMonitors()
    }

    /// The island under the pointer, else the one on the built-in display.
    var primary: IslandController? {
        let p = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }),
           let c = controllers[Self.displayID(screen)] { return c }
        return controllers.values.first { $0.model.notch.isHardware } ?? controllers.values.first
    }

    func toggleDashboard() { primary?.toggleDashboard() }

    // MARK: displays

    private func rebuild() {
        let targets = targetScreens()
        let ids = Set(targets.map(Self.displayID))
        for (id, c) in controllers where !ids.contains(id) {
            c.close()
            controllers[id] = nil
        }
        for screen in targets {
            let id = Self.displayID(screen)
            if let c = controllers[id] { c.update(screen: screen) }
            else { controllers[id] = IslandController(screen: screen, displayID: id, env: env) }
        }
    }

    private func targetScreens() -> [NSScreen] {
        switch env.settings.settings.displays {
        case .all:
            return NSScreen.screens
        case .builtIn:
            let notched = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
            // Lid closed or a Mac without a notch: use the menu bar display.
            return notched.isEmpty ? Array(NSScreen.screens.prefix(1)) : notched
        }
    }

    /// Opens the shelf when a drag carrying files, images, links or text comes
    /// near the top of the screen around the notch.
    private func checkDragTowardNotch(at p: NSPoint) {
        let s = env.settings.settings
        guard !dragOpenedShelf, s[module: .shelf].enabled, s.shelf.openOnDrag else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragBaseline else { return }
        let types = Set(pb.types ?? [])
        let carries: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff, .string]
        guard !types.isDisjoint(with: carries),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }),
              let c = controllers[Self.displayID(screen)] else { return }
        let notch = c.model.notch.rect
        let nearTop = p.y >= screen.frame.maxY - s.shelf.dragActivationDistance
        let nearNotch = abs(p.x - notch.midX) <= IslandMetrics.shelf.width / 2 + 60
        guard nearTop, nearNotch else { return }
        dragOpenedShelf = true
        c.openShelfForDrag()
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    // MARK: mouse

    private func installMonitors() {
        let global: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: global, handler: { [weak self] event in
            let type = event.type
            _ = MainActor.assumeIsolated { self?.handle(type: type, event: nil) }
        }) { monitors.append(m) }

        let local: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel]
        if let m = NSEvent.addLocalMonitorForEvents(matching: local, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(type: event.type, event: event) ?? false }
            return consumed ? nil : event
        }) { monitors.append(m) }
    }

    /// Returns true when a local event was consumed.
    private func handle(type: NSEvent.EventType, event: NSEvent?) -> Bool {
        let p = NSEvent.mouseLocation
        switch type {
        case .mouseMoved:
            controllers.values.forEach { $0.pointerMoved(to: p) }
        case .leftMouseDragged:
            if event == nil { checkDragTowardNotch(at: p) }
            controllers.values.forEach { $0.pointerMoved(to: p) }
        case .leftMouseDown:
            dragBaseline = NSPasteboard(name: .drag).changeCount
            controllers.values.forEach { $0.mouseDownOutside(at: p) }
        case .leftMouseUp:
            if dragOpenedShelf {
                dragOpenedShelf = false
                controllers.values.forEach { $0.dragEnded() }
            }
        case .rightMouseDown:
            if let c = controllers.values.first(where: { $0.contains(p) }) {
                c.showMenu()
                return event != nil
            }
        case .scrollWheel:
            if let event, let c = controllers.values.first(where: { $0.contains(p) }) {
                return c.scroll(event)
            }
        default:
            break
        }
        return false
    }
}

/// Calls `onChange` whenever the observed value changes, for as long as the app runs.
@MainActor
func whenChanged<T: Equatable>(_ read: @escaping @MainActor () -> T, onChange: @escaping @MainActor (T) -> Void) {
    let tracker = ObservationLoop(read: read, onChange: onChange)
    tracker.track()
}

@MainActor
private final class ObservationLoop<T: Equatable> {
    let read: @MainActor () -> T
    let onChange: @MainActor (T) -> Void
    var last: T

    init(read: @escaping @MainActor () -> T, onChange: @escaping @MainActor (T) -> Void) {
        self.read = read
        self.onChange = onChange
        last = read()
    }

    /// Re-registers after every change; the closure keeps `self` alive.
    func track() {
        withObservationTracking {
            _ = read()
        } onChange: {
            Task { @MainActor in
                let value = self.read()
                if value != self.last { self.last = value; self.onChange(value) }
                self.track()
            }
        }
    }
}
