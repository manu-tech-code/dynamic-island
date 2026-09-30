# Phase 0 spike results

macOS 27.0.1 (26A434) · M5 MacBook Pro 14" + S27C31x external · Xcode 27 · Swift 6.4
Run on 30 Sep 2026. Material decision: **Hybrid**.

Build and package: `./scripts/bundle.sh` produces signed apps in `build/`. It signs with your Apple Development identity so permissions persist between builds.
Launch each spike with `open`, not by running the binary from a shell. When run from a shell, macOS attributes permissions to the parent app (Terminal or Claude) instead of the spike.

| # | Question | Result | Evidence |
|---|---|---|---|
| 1 | Can a panel sit over the notch, above the menu bar, on every Space and over full-screen apps? | **Pass (automated), visual check pending** | Layer 27 (above the menu bar), on screen, `onActiveSpace=true` before, during and after an own-window full-screen transition. Occlusion goes false only during the Space animation. |
| 2 | Does real system glass render in a non-activating panel and follow the Liquid Glass slider? | **Pass** | You confirmed the island and lab glass change live as the slider moves. From your screenshot: every tile looks the same in the key window and the non-key panel, so glass doesn't go flat when the window isn't key. SwiftUI glass takes the custom notch shape (tile C). AppKit glass ignores a layer mask: tile F draws as a rounded rectangle although the log shows the mask was set. The notch shape must therefore be SwiftUI. |
| 3 | Can we read Now Playing on macOS 27? | **Pass** | Direct in-process MediaRemote is **blocked** (`info=null, pid=0`). The `/usr/bin/perl` route returns full metadata in 15 ms, including 600×600 artwork, elapsed time, duration and the source app PID. The AppleScript fallback to Music also works. |
| 4 | Does reading the clipboard trigger the paste alert? | **Pass on this Mac** | `accessBehavior = alwaysAllow`, even launched via LaunchServices. Reading a string returned instantly with no alert. `detectedPatterns` works without reading. `detectedMetadata(contentType)` fails with error 67587. |

## Details

### 1 · Overlay panel
- Notch rect from `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`: **(663.5, 950) 185 × 32 pt**. Menu bar: 33 pt.
- The external display reports no safe area and nil aux areas, so a virtual notch is needed there.
- Panel config that works: `[.borderless, .nonactivatingPanel]`, level `mainMenu + 3` (= 27), `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`, clear background, `canBecomeKey = false`.
- Hit testing: the panel stays click-through (`ignoresMouseEvents`) until a global `mouseMoved` monitor sees the pointer over the island. This needs no permission.
- Clicks on the island are received in the non-activating panel (log 13:40:17 and 13:40:19). The panel stayed on the active Space through about 25 Space changes.
- **Finding: the compact ears cover menu bar items next to the notch.** The spike's own status item sits at x 851–886 pt, directly under the right ear (the island spans 610–903 pt). On a crowded menu bar macOS packs items right up to the notch. Phase 1 needs a policy for this: show ears only while something is live, keep them narrow, or add a compact style that grows downward instead of sideways.
- Consequence: the real app can't rely on its own menu bar icon being reachable. The island's right-click menu is the primary control.
- Not yet checked visually: a real full-screen app (Safari video), Mission Control, Stage Manager, whether clicking the island steals focus (now logged as `frontApp` on each click).

### 3 · Now Playing
- MediaRemote on macOS 27 still rejects non-allow-listed clients. `/usr/bin/perl` (5.34, Apple platform binary) loads our own `libNowPlayingBridge.dylib` through `DynaLoader`, and MediaRemote answers it.
- This is our own ~150-line bridge. No third-party code is involved.
- Not yet tested: the change stream while you play/pause/skip, and sending commands (play/pause/next). Both need you to play something.
- Fallback: AppleScript to Music (and to Spotify when it's running) returns state, title and artist. The app never launches a player itself.

### 4 · Clipboard
- Apple's default for apps is "ask", but this Mac reports "always allow" for the spike. It's probably your Paste-from-other-apps setting.
- Design: check `accessBehavior` at runtime, make clipboard history opt-in, and use `detectedPatterns` (alert-free) for previews.

### Discovery probes (for the slider)
- Observing all distributed notifications (`name: nil`) delivered **nothing** in over an hour. It's filtered for non-root processes.
- **The slider is readable.** Moving it writes `NSGlassTintAmount` (Double, 0 = clear … 1 = tinted) to `NSGlobalDomain`. Our 1.5 s defaults diff saw every move (0.61 → 1 → 0 → 0.41 → … → 0.71). It isn't in Apple's documentation, so we use it only as a hint for custom-drawn parts (for example the collar fade or the virtual notch). The glass body follows the slider by itself.
- **KVO works as a push.** String-key KVO on `UserDefaults.standard` fired for most slider moves before the 1.5 s poll saw them (for example 14:40:45.272 KVO vs .405 poll, 14:40:46.640 vs .905). A few KVO hits arrived only right after the poll read the domain, so the app uses KVO plus a slow fallback read (on wake, on display change, and every ~10 s while a custom-drawn surface is visible).

### Focus
- 29 clicks on the island in the non-activating panel. The front app stayed Slack, Claude or System Settings every time, so the island **never steals focus**.

### Compact style (decision: option c, both as a setting)
- `Beside the notch`: ears, 54 pt each side, 32 pt tall. Covers menu bar items next to the notch.
- `Below the notch`: notch width + 12 pt each side, 32 + 28 pt tall, with content in the band under the camera. Covers no menu bar items.
- Both are in the spike's right-click menu under **Compact style**.

## Manual checks (you)
With `NotchGlassSpike` running, it shows the island expanded, a Glass lab window and a Glass lab panel:
1. Does the island look like the design: black at the notch, glass below, and does the glass show your wallpaper and windows through it?
2. Move **System Settings › Appearance › Liquid Glass** slider from clear to tinted. Do the island and all six lab tiles change **live**? Do the key-window and non-key-panel tiles match?
3. Toggle **Reduce transparency** and **Increase contrast** (Accessibility › Display). Island text updates, and does the glass go frosted or bordered?
4. Hover the island and click it (it should collapse and expand with a spring). Click elsewhere to collapse. Does clicking steal focus from your current app?
5. Play a YouTube video full screen in Safari. Is the island still there? Also open Mission Control.
6. Menu bar icon (capsule): switch Material between Hybrid, Glass and Black, and Glass between Regular and Clear.
7. Which lab tile (A–F) looks best? Tile F tests whether an AppKit glass view can take the notch shape through a mask.

Log: `~/Library/Logs/IslandSpikes/NotchGlass.log`
