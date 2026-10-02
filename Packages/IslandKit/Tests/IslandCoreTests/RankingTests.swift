import Foundation
import Testing
@testable import IslandCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func act(_ id: String, _ kind: ActivityKind, relevance: Double = 0.5, started: TimeInterval = 0) -> Activity {
    let payload: ActivityPayload = switch kind {
    case .nowPlaying: .nowPlaying(NowPlayingInfo(title: id))
    case .timer: .timer(TimerInfo(label: id, duration: 60, endDate: t0.addingTimeInterval(60)))
    case .calendar: .calendar(CalendarEventInfo(id: id, title: id, start: t0, end: t0.addingTimeInterval(600)))
    case .battery: .battery(BatteryInfo(hasBattery: true, percent: 9, isCharging: false, isPluggedIn: false))
    case .backgroundApps: .backgroundApps([])
    case .shelf: .shelf([])
    case .downloads: .download(DownloadInfo(id: id, name: id))
    case .privacy: .privacy(PrivacyInfo(microphone: true, camera: false))
    case .messages: .messages([UnreadApp(app: id, count: 1, lastSender: id)])
    case .devices, .hud: .backgroundApps([])
    }
    return Activity(id: id, kind: kind, payload: payload, relevance: relevance, startedAt: t0.addingTimeInterval(started))
}

@Suite struct RankingTests {
    let all = Set(ActivityKind.allCases)

    @Test func followsUserPriority() {
        let r = ActivityRanking.rank([act("m", .nowPlaying), act("t", .timer), act("c", .calendar)],
                                     order: [.timer, .calendar, .nowPlaying], compactKinds: all, limit: nil)
        #expect(r.visible.map(\.id) == ["t", "c", "m"])
        #expect(r.overflow.isEmpty)
    }

    @Test func limitSplitsIntoOverflow() {
        let r = ActivityRanking.rank([act("m", .nowPlaying), act("t", .timer), act("c", .calendar)],
                                     order: [.nowPlaying, .timer, .calendar], compactKinds: all, limit: 2)
        #expect(r.visible.map(\.id) == ["m", "t"])
        #expect(r.overflow.map(\.id) == ["c"])
        #expect(r.primary?.id == "m")
        #expect(r.secondaries.map(\.id) == ["t"])
    }

    @Test func limitBelowOneStillShowsOne() {
        let r = ActivityRanking.rank([act("m", .nowPlaying), act("t", .timer)], order: [], compactKinds: all, limit: 0)
        #expect(r.visible.count == 1)
    }

    @Test func tiesGoToRelevanceThenStartTime() {
        let a = act("a", .timer, relevance: 0.5, started: 10)
        let b = act("b", .timer, relevance: 0.9, started: 20)
        let c = act("c", .timer, relevance: 0.5, started: 5)
        let r = ActivityRanking.rank([a, b, c], order: [.timer], compactKinds: all, limit: nil)
        #expect(r.visible.map(\.id) == ["b", "c", "a"])
    }

    @Test func excludesKindsNotAllowedInCompact() {
        let r = ActivityRanking.rank([act("m", .nowPlaying), act("t", .timer)], order: [], compactKinds: [.timer], limit: nil)
        #expect(r.all.map(\.id) == ["t"])
    }

    @Test func kindsMissingFromOrderRankLast() {
        let r = ActivityRanking.rank([act("b", .battery), act("m", .nowPlaying)], order: [.battery], compactKinds: all, limit: nil)
        #expect(r.visible.map(\.id) == ["b", "m"])
    }
}
