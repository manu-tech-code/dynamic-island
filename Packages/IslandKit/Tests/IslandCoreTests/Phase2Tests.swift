import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct Phase2SettingsTests {
    @Test func migratesVersionOneModuleKeys() {
        let json = #"{"timerModule":{"enabled":false,"showInCompact":true},"batteryModule":{"enabled":true,"showInCompact":false}}"#
        let s = IslandSettings.decode(Data(json.utf8))
        #expect(s[module: .timer].enabled == false)
        #expect(s[module: .battery].showInCompact == false)
        #expect(s[module: .nowPlaying] == ActivityKind.nowPlaying.defaultModule)
    }

    @Test func nestedGroupsFillMissingFields() {
        let s = IslandSettings.decode(Data(#"{"nowPlaying":{"keepPausedMinutes":9}}"#.utf8))
        #expect(s.nowPlaying.keepPausedMinutes == 9)
        #expect(s.nowPlaying.lyricsEnabled == true) // absent in the file, from defaults
    }

    @Test func badNestedValueFallsBackForThatGroupOnly() {
        let s = IslandSettings.decode(Data(#"{"weather":{"unit":"kelvin"},"material":"glass"}"#.utf8))
        #expect(s.weather.unit == .automatic)
        #expect(s.material == .glass)
    }

    @Test func hudStartsOffAndDevicesNeverLive() {
        let s = IslandSettings()
        #expect(!s[module: .hud].enabled)
        #expect(!s.compactKinds.contains(.devices))
        #expect(!s.compactKinds.contains(.hud))
        #expect(s.compactKinds.contains(.shelf))
    }

    @Test func priorityGetsNewKindsButNotAlertOnlyOnes() {
        let s = IslandSettings.decode(Data(#"{"priority":["timer","hud","nowPlaying"]}"#.utf8))
        #expect(s.priority.first == .timer)
        #expect(s.priority.contains(.downloads))
        #expect(!s.priority.contains(.hud))
        #expect(!s.priority.contains(.devices))
    }

    @Test func roundTripsNewGroups() {
        var s = IslandSettings()
        s.clipboard.enabled = true
        s.shortcuts.pinned = ["Morning", "Focus"]
        s.weather.placeName = "Accra"
        s[module: .hud].enabled = true
        #expect(IslandSettings.decode(s.encoded()) == s)
    }
}

@Suite struct Phase2LogicTests {
    @Test func decodesMediaKeys() {
        let volumeUpDown = (0 << 16) | (0xA << 8)
        #expect(MediaKey.decode(data1: volumeUpDown) == .init(key: .soundUp, isDown: true, isRepeat: false))
        let muteUp = (7 << 16) | (0xB << 8)
        #expect(MediaKey.decode(data1: muteUp)?.isDown == false)
        let brightnessRepeat = (2 << 16) | (0xA << 8) | 1
        #expect(MediaKey.decode(data1: brightnessRepeat)?.isRepeat == true)
        #expect(MediaKey.decode(data1: (16 << 16) | (0xA << 8)) == nil) // play key: not ours
    }

    @Test func volumeSteps() {
        #expect(VolumeMath.step(0.5, up: true, steps: 16, fine: false) == 0.5625)
        #expect(VolumeMath.step(0, up: false, steps: 16, fine: false) == 0)
        #expect(VolumeMath.step(1, up: true, steps: 16, fine: false) == 1)
        #expect(VolumeMath.step(0.5, up: true, steps: 16, fine: true) == 0.515625)
        #expect(VolumeMath.step(0.51, up: true, steps: 16, fine: false) == 0.5625) // snaps to the grid
    }

    @Test func downloadNames() {
        #expect(DownloadNames.clean("Report.pdf.download") == "Report.pdf")
        #expect(DownloadNames.clean("movie.mp4.crdownload") == "movie.mp4")
        #expect(DownloadNames.clean("plain.zip") == "plain.zip")
    }

    @Test func clipboardHistoryMovesDuplicatesUp() {
        let a = ClipboardEntry(content: .text("a"), sourceApp: nil, fingerprint: "a")
        let b = ClipboardEntry(content: .text("b"), sourceApp: nil, fingerprint: "b")
        var list = ClipboardHistory.inserting(a, into: [], max: 3)
        list = ClipboardHistory.inserting(b, into: list, max: 3)
        list = ClipboardHistory.inserting(ClipboardEntry(content: .text("a"), sourceApp: nil, fingerprint: "a"), into: list, max: 3)
        #expect(list.map(\.fingerprint) == ["a", "b"])
        let capped = (0..<10).reduce([ClipboardEntry]()) { l, i in
            ClipboardHistory.inserting(ClipboardEntry(content: .text("\(i)"), sourceApp: nil, fingerprint: "\(i)"), into: l, max: 3)
        }
        #expect(capped.map(\.fingerprint) == ["9", "8", "7"])
    }

    @Test func weatherForecastParses() throws {
        let json = """
        {"current":{"temperature_2m":28.4,"apparent_temperature":31,"weather_code":2,"is_day":1},
         "hourly":{"time":[1000,4600,8200,11800],"temperature_2m":[27,28,29,30],"weather_code":[1,2,3,61],"is_day":[1,1,1,0]},
         "daily":{"temperature_2m_max":[31],"temperature_2m_min":[24]}}
        """
        let r = try #require(OpenMeteo.parseForecast(Data(json.utf8), now: Date(timeIntervalSince1970: 3000), hourCount: 2))
        #expect(r.temperature == 28.4)
        #expect(r.condition.summary == "Partly cloudy")
        #expect(r.high == 31 && r.low == 24)
        #expect(r.hours.map(\.temperature) == [28, 29]) // 1000 is more than 30 min in the past
        #expect(OpenMeteo.forecastURL(latitude: 5.61234, longitude: -0.18765, fahrenheit: true)?.absoluteString.contains("latitude=5.61") == true)
    }

    @Test func weatherSymbols() {
        #expect(WeatherCondition(code: 0, isDay: false).symbolName == "moon.stars.fill")
        #expect(WeatherCondition(code: 95, isDay: true).summary == "Thunderstorm")
    }

    @Test func hudSizeFollowsCompactStyle() {
        let notch = CGSize(width: 185, height: 32)
        let beside = IslandMetrics.alertSize(for: .volume(level: 0.5, muted: false, output: "x"), notch: notch, compactStyle: .beside)
        let below = IslandMetrics.alertSize(for: .volume(level: 0.5, muted: false, output: "x"), notch: notch, compactStyle: .below)
        #expect(beside.height == CGFloat(32))
        #expect(below.height > beside.height)
    }
}
