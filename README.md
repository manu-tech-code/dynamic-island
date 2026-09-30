# Dynamic Island for Mac

A configurable Dynamic Island around the MacBook notch, drawn with the system's
own Liquid Glass so it follows your appearance settings.

## Build and run

Requires macOS 26+, Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/run.sh            # generate the project, build Debug, relaunch the app
scripts/run.sh --no-run   # build only
cd Packages/IslandKit && swift test   # core logic tests
```

The Xcode project is generated from `project.yml` and isn't committed. Run
`xcodegen generate` after adding or removing files, then open
`DynamicIsland.xcodeproj` if you want Xcode.

Builds are signed with your Apple Development identity, so macOS keeps
permissions (Calendars, Automation) between builds.

## Layout

| Path | What |
|---|---|
| `Packages/IslandKit` | UI-free logic: activity model, ranking, layout metrics, settings, parsers. Unit-tested. |
| `App/DynamicIsland` | The app: island panel and views, modules, settings window. |
| `App/NowPlayingBridge` | MediaRemote reader loaded by `/usr/bin/perl` (see `Spikes/RESULTS.md`). |
| `Spikes` | Phase 0 feasibility spikes and their results. |

## Using it

- Click the island to expand it; click an idle island for the dashboard.
- Scroll down on the island to open, up to close. Right-click for the menu.
- <kbd>⌥⌘I</kbd> opens or closes the dashboard from anywhere.
- Drag a file toward the notch to open the shelf; drop to keep it, drag it out later.
- Settings: right-click › Settings…, or open the app again from Finder.

### Links for Shortcuts and scripts

```sh
open "dynamicisland://dashboard"
open "dynamicisland://timer?minutes=25&label=Focus"
open "dynamicisland://play-pause"     # also: next, previous, collapse, settings
open "dynamicisland://shelf"          # also: lyrics, up-next
```

Log file: `~/Library/Logs/DynamicIsland/DynamicIsland.log`
