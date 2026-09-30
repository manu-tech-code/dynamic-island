import Foundation
import Testing
@testable import IslandCore

@Suite struct SettingsTests {
    @Test func roundTrips() {
        var s = IslandSettings()
        s.material = .glass
        s.compactStyle = .below
        s.maxActivities = 7
        s.backgroundApps.maxIcons = 9
        s[module: .calendar].showInCompact = false
        #expect(IslandSettings.decode(s.encoded()) == s)
    }

    @Test func missingKeysUseDefaults() {
        let s = IslandSettings.decode(#"{"material":"black","backgroundApps":{"maxIcons":6}}"#.data(using: .utf8)!)
        #expect(s.material == .black)
        #expect(s.backgroundApps.maxIcons == 6)
        #expect(s.backgroundApps.excludedBundleIDs == ["com.apple.finder"])
        #expect(s.compactStyle == .beside)
        #expect(s.priority.count == ActivityKind.allCases.count)
    }

    @Test func garbageFallsBackToDefaults() {
        #expect(IslandSettings.decode(Data("nope".utf8)) == IslandSettings())
    }

    @Test func normalizesPriorityAndClamps() {
        let s = IslandSettings.decode(#"{"priority":["timer","timer","bogus"],"maxActivities":99,"hoverDelayMs":-5}"#.data(using: .utf8)!)
        #expect(s.priority.first == .timer)
        #expect(Set(s.priority) == Set(ActivityKind.allCases))
        #expect(s.priority.count == ActivityKind.allCases.count)
        #expect(s.maxActivities == 12)
        #expect(s.hoverDelayMs == 0)
    }

    @Test func zeroMeansUnlimited() {
        var s = IslandSettings()
        s.maxActivities = 0
        #expect(s.activityLimit == nil)
    }

    @Test func compactKindsHonourModuleToggles() {
        var s = IslandSettings()
        s[module: .battery].enabled = false
        s[module: .timer].showInCompact = false
        #expect(!s.compactKinds.contains(.battery))
        #expect(!s.compactKinds.contains(.timer))
        #expect(s.compactKinds.contains(.nowPlaying))
    }
}

@Suite struct ParsingTests {
    @Test func parsesBridgeLine() throws {
        let line = """
        {"event":"InfoDidChangeNotification","at":1790775376.7,"artworkKey":"abc","artwork":"AAEC",
         "state":{"ok":1,"isPlaying":1,"pid":69671,"info":{"Title":"Song","Artist":"Artist","Album":"Album",
         "Duration":232.5,"ElapsedTime":84,"Timestamp":1790775370,"PlaybackRate":1}}}
        """
        let u = try #require(NowPlayingParser.parse(line: Data(line.utf8)))
        let info = try #require(u.info)
        #expect(info.title == "Song")
        #expect(info.artist == "Artist")
        #expect(info.isPlaying)
        #expect(info.duration == 232.5)
        #expect(info.sourcePID == 69671)
        #expect(info.artworkKey == "abc")
        #expect(u.artworkData == Data([0, 1, 2]))
        let e = try #require(info.elapsed(at: Date(timeIntervalSince1970: 1790775380)))
        #expect(abs(e - 94) < 0.001)
    }

    @Test func nothingPlaying() throws {
        let u = try #require(NowPlayingParser.parse(line: Data(#"{"event":"start","state":{"ok":1,"info":null,"pid":0}}"#.utf8)))
        #expect(u.info == nil)
    }

    @Test func pausedDoesNotAdvance() {
        let info = NowPlayingInfo(title: "x", duration: 100, elapsedAtTimestamp: 40, timestamp: Date(timeIntervalSince1970: 0), playbackRate: 0, isPlaying: false)
        #expect(info.elapsed(at: Date(timeIntervalSince1970: 500)) == 40)
    }

    @Test func elapsedClampsToDuration() {
        let info = NowPlayingInfo(title: "x", duration: 100, elapsedAtTimestamp: 90, timestamp: Date(timeIntervalSince1970: 0), playbackRate: 1, isPlaying: true)
        #expect(info.elapsed(at: Date(timeIntervalSince1970: 60)) == 100)
    }

    @Test func meetingLinks() {
        #expect(MeetingLinks.joinURL(url: nil, location: "Room 4", notes: "Join: https://us02web.zoom.us/j/123?pwd=x") != nil)
        #expect(MeetingLinks.joinURL(url: URL(string: "https://meet.google.com/abc-defg-hij"), location: nil, notes: nil)?.host == "meet.google.com")
        #expect(MeetingLinks.joinURL(url: URL(string: "https://example.com/agenda"), location: "https://teams.microsoft.com/l/meetup-join/x", notes: nil)?.host == "teams.microsoft.com")
        #expect(MeetingLinks.joinURL(url: URL(string: "https://notzoom.us.evil.com"), location: nil, notes: nil) == nil)
        #expect(MeetingLinks.joinURL(url: nil, location: nil, notes: "Lunch at https://example.com") == nil)
    }

    @Test func formatting() {
        #expect(IslandFormat.countdown(299.2) == "5:00")
        #expect(IslandFormat.countdown(59) == "0:59")
        #expect(IslandFormat.countdown(3723) == "1:02:03")
        #expect(IslandFormat.position(84.9) == "1:24")
        let now = Date(timeIntervalSince1970: 0)
        #expect(IslandFormat.untilShort(now.addingTimeInterval(-5), from: now) == "Now")
        #expect(IslandFormat.untilShort(now.addingTimeInterval(12 * 60 - 30), from: now) == "12m")
        #expect(IslandFormat.untilShort(now.addingTimeInterval(65 * 60), from: now) == "1h 5m")
        #expect(IslandFormat.untilLong(now.addingTimeInterval(18 * 60), from: now) == "in 18 min")
        #expect(IslandFormat.duration(minutes: 220) == "3 h 40 m")
    }

    @Test func timerMath() {
        let now = Date(timeIntervalSince1970: 100)
        let running = TimerInfo(label: "Tea", duration: 300, endDate: now.addingTimeInterval(120))
        #expect(running.remaining(at: now) == 120)
        #expect(abs(running.fractionRemaining(at: now) - 0.4) < 0.0001)
        #expect(!running.isFinished(at: now))
        #expect(running.isFinished(at: now.addingTimeInterval(121)))
        let paused = TimerInfo(label: "Tea", duration: 300, endDate: nil, pausedRemaining: 42)
        #expect(paused.isPaused)
        #expect(paused.remaining(at: now) == 42)
    }
}
