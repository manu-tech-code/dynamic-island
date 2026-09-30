import AppKit

/// A window space above the lock screen, through the private SkyLight
/// framework (the approach of Lakr233's SkyLightWindow). A window moved into
/// it stays visible while the Mac is locked. If the symbols are missing, or
/// macOS refuses, `adopt` does nothing and the window only shows once unlocked.
enum LockScreenSpace {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void

    private struct Space {
        let connection: Int32
        let id: UInt64
        let add: AddWindows
    }

    /// Created once, the first time a window asks for it.
    private static let space: Space? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as _: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
        guard let main = symbol("SLSMainConnectionID", as: MainConnectionID.self),
              let create = symbol("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = symbol("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let show = symbol("SLSShowSpaces", as: ShowSpaces.self),
              let add = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self) else {
            Log.error("lock screen space: SkyLight symbols missing")
            return nil
        }
        let connection = main()
        let id = create(connection, 1, 0)
        let level = setLevel(connection, id, 100)
        let shown = show(connection, [NSNumber(value: id)] as CFArray)
        Log.info("lock screen space \(id): level \(level), shown \(shown)")
        return Space(connection: connection, id: id, add: add)
    }()

    static func adopt(_ window: NSWindow) {
        guard let space, window.windowNumber > 0 else { return }
        space.add(space.connection, space.id, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }
}
