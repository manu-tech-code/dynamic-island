import Foundation
import Testing
@testable import IslandCore

/// Defaults that changed so the app behaves on every Mac, not only one with a
/// notch: new installs get them, saved settings keep what they had.
@Suite struct NewDefaultsTests {
    @Test func newInstallsStartQuiet() {
        let s = IslandSettings()
        #expect(s.hotKey == nil)
        #expect(!s.virtualNotchWhenIdle)
        #expect(!s.nowPlaying.waveformFollowsAudio)
    }

    @Test func noShortcutRoundTrips() {
        let s = IslandSettings.decode(IslandSettings().encoded())
        #expect(s.hotKey == nil)
        #expect(s == IslandSettings())
    }

    @Test func savedSettingsKeepTheirValues() {
        // Saved by 0.12.0, which wrote every field with the old defaults.
        let saved = #"""
        {"hotKey":{"keyCode":34,"carbonModifiers":2304,"label":"⌥⌘I"},"virtualNotchWhenIdle":true,
         "nowPlaying":{"keepPausedMinutes":3,"lyricsEnabled":true,"showUpNext":true,"titleOnHover":true,
                       "titleOnTrackChange":true,"waveformFollowsAudio":true}}
        """#
        let s = IslandSettings.decode(Data(saved.utf8))
        #expect(s.hotKey == HotKeySpec(keyCode: 34, carbonModifiers: HotKeySpec.command | HotKeySpec.option, label: "⌥⌘I"))
        #expect(s.virtualNotchWhenIdle)
        #expect(s.nowPlaying.waveformFollowsAudio)
        #expect(IslandSettings.decode(s.encoded()) == s)
    }

    @Test func savedOffStaysOff() {
        let s = IslandSettings.decode(Data(#"{"virtualNotchWhenIdle":false,"nowPlaying":{"waveformFollowsAudio":false}}"#.utf8))
        #expect(!s.virtualNotchWhenIdle)
        #expect(!s.nowPlaying.waveformFollowsAudio)
        #expect(s.hotKey == nil)
    }

    @Test func anEarlierInstallWithNothingSavedKeepsItsDefaults() {
        let s = IslandSettings.earlierDefaults
        #expect(s.hotKey?.label == "⌥⌘I")
        #expect(s.hotKey?.menuKey == "i")
        #expect(s.virtualNotchWhenIdle)
        #expect(s.nowPlaying.waveformFollowsAudio)
        // Everything else is today's default, and modules stay on.
        var rest = s
        rest.hotKey = nil
        rest.virtualNotchWhenIdle = false
        rest.nowPlaying.waveformFollowsAudio = false
        #expect(rest == IslandSettings())
        #expect(IslandSettings.decode(s.encoded()) == s)
    }

    @Test func aBrokenShortcutMeansNone() {
        let s = IslandSettings.decode(Data(#"{"hotKey":{"keyCode":"x"},"material":"black"}"#.utf8))
        #expect(s.hotKey == nil)
        #expect(s.material == .black)
    }
}

@Suite struct NewInstallTests {
    @Test func macBookWithANotch() {
        let s = IslandSettings.newInstall(on: MacTraits(hasNotch: true, hasBattery: true))
        #expect(s.compactStyle == .beside)
        #expect(s.dashboard.contains { $0.kind == .battery })
        // Nothing asks for permission until it's turned on.
        for kind in ActivityKind.asksPermission { #expect(!s[module: kind].enabled) }
        #expect(s[module: .nowPlaying].enabled)
        #expect(s[module: .timer].enabled)
        #expect(!s.nowPlaying.waveformFollowsAudio)
        #expect(s.hotKey == nil)
    }

    @Test func desktopWithoutANotchOrABattery() {
        let s = IslandSettings.newInstall(on: MacTraits(hasNotch: false, hasBattery: false))
        #expect(s.compactStyle == .below)
        #expect(!s.dashboard.contains { $0.kind == .battery })
        #expect(s.dashboard.contains { $0.kind == .cpu })
    }

    @Test func permissionsAlreadyGivenStayOn() {
        let s = IslandSettings.newInstall(on: MacTraits(hasNotch: true, hasBattery: true, allowed: [.calendar]))
        #expect(s[module: .calendar].enabled)
        #expect(!s[module: .devices].enabled)
        #expect(!s[module: .downloads].enabled)
    }

    @Test func newInstallChoicesAreSaved() {
        let s = IslandSettings.newInstall(on: MacTraits(hasNotch: false, hasBattery: false))
        let again = IslandSettings.decode(s.encoded())
        #expect(again == s)
        #expect(!again[module: .calendar].enabled)
        #expect(again.compactStyle == .below)
    }

    @Test func savedSettingsWithoutModuleEntriesKeepModulesOn() {
        // An existing user who never touched the modules keeps them on.
        let s = IslandSettings.decode(Data(#"{"material":"glass"}"#.utf8))
        for kind in ActivityKind.asksPermission { #expect(s[module: kind].enabled) }
        #expect(s.compactStyle == .beside)
        #expect(s.dashboard.contains { $0.kind == .battery })
    }
}

@Suite struct HotKeyMenuTests {
    @Test func lettersAreLowercase() {
        #expect(HotKeySpec(keyCode: 34, carbonModifiers: HotKeySpec.command | HotKeySpec.option, label: "⌥⌘I").menuKey == "i")
        #expect(HotKeySpec(keyCode: 2, carbonModifiers: HotKeySpec.command | HotKeySpec.shift, label: "⇧⌘D").menuKey == "d")
    }

    @Test func specialKeys() {
        #expect(HotKeySpec(keyCode: 49, carbonModifiers: HotKeySpec.control, label: "⌃Space").menuKey == " ")
        #expect(HotKeySpec(keyCode: 36, carbonModifiers: HotKeySpec.command, label: "⌘↩").menuKey == "\r")
        #expect(HotKeySpec(keyCode: 126, carbonModifiers: HotKeySpec.option, label: "⌥↑").menuKey == "\u{F700}")
        #expect(HotKeySpec(keyCode: 96, carbonModifiers: HotKeySpec.command, label: "⌘F5").menuKey == "\u{F708}")
        #expect(HotKeySpec(keyCode: 111, carbonModifiers: HotKeySpec.command, label: "⌘F12").menuKey == "\u{F70F}")
    }

    @Test func unknownKeysHaveNoMenuKey() {
        #expect(HotKeySpec(keyCode: 0, carbonModifiers: HotKeySpec.command, label: "⌘Fn").menuKey == nil)
        #expect(HotKeySpec(keyCode: 0, carbonModifiers: HotKeySpec.command, label: "⌘").menuKey == nil)
    }
}
