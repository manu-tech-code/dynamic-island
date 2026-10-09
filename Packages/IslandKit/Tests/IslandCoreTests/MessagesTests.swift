import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct MessagesTests {
    let notch = CGSize(width: 185, height: 32)

    @Test func readsTheAppFromABanner() {
        // As Notification Center describes a banner to Accessibility.
        #expect(MessageInfo.appName(fromBannerDescription: "WhatsApp, Ama Mensah, Are we still on for 6?", title: "Ama Mensah") == "WhatsApp")
        #expect(MessageInfo.appName(fromBannerDescription: "Microsoft Teams, Sarah, Daily sync, Running late", title: "Sarah") == "Microsoft Teams")
        #expect(MessageInfo.appName(fromBannerDescription: "Script Editor, Ama Mensah, Test message, Hello", title: "Ama Mensah") == "Script Editor")
        // No title: the first part.
        #expect(MessageInfo.appName(fromBannerDescription: "Calendar, Standup in 5 minutes", title: "") == "Calendar")
    }

    @Test func initialsForTheSendersCircle() {
        #expect(MessageInfo(id: "1", app: "WhatsApp", sender: "Ama Mensah", text: "").initials == "AM")
        #expect(MessageInfo(id: "2", app: "Slack", sender: "#design", text: "").initials == "D")
        #expect(MessageInfo(id: "3", app: "Messages", sender: "Mum", text: "").initials == "M")
        #expect(MessageInfo(id: "4", app: "Mail", sender: "", text: "").initials == "M")
    }

    @Test func knowsMessagingApps() {
        #expect(MessagingApps.isMessaging(app: "WhatsApp", bundleID: nil))
        #expect(MessagingApps.isMessaging(app: "Anything", bundleID: "com.tinyspeck.slackmacgap"))
        #expect(MessagingApps.isMessaging(app: "Microsoft Teams", bundleID: nil))
        #expect(!MessagingApps.isMessaging(app: "Script Editor", bundleID: "com.apple.ScriptEditor2"))
        #expect(!MessagingApps.isMessaging(app: "Calendar", bundleID: "com.apple.iCal"))
        // Music announces songs; the island shows them already.
        #expect(MessagingApps.isMedia(app: "Music") && MessagingApps.isMedia(app: "Spotify"))
        #expect(!MessagingApps.isMedia(app: "WhatsApp"))
    }

    @Test func settingsDefaultToACardAndRoundTrip() throws {
        let s = IslandSettings()
        #expect(s.messages.style == .card)
        #expect(!s.messages.hideText && s.messages.apps.isEmpty)
        #expect(s.messages.hideSystemBanner)                    // once, on the island
        #expect(s[module: .messages].enabled)
        let old = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"messages":{"style":"stack"}}"#.utf8))
        #expect(old.messages.style == .stack)
        #expect(old.messages.holdSeconds == 5)                 // missing fields fill in
        for style in MessageAlertStyle.allCases {
            var t = IslandSettings()
            t.messages.style = style
            #expect(IslandSettings.decode(t.encoded()).messages.style == style)
        }
        #expect(Set(MessageAlertStyle.allCases.map(\.displayName)).count == MessageAlertStyle.allCases.count)
        // Existing priority lists gain the new kind where it belongs, not last: after timers.
        let saved = #"{"priority":["calendar","nowPlaying","timer","downloads","privacy","battery","shelf","backgroundApps"]}"#
        let repaired = try JSONDecoder().decode(IslandSettings.self, from: Data(saved.utf8)).normalized()
        #expect(repaired.priority == [.calendar, .nowPlaying, .timer, .agents, .messages, .downloads, .privacy, .battery, .shelf, .backgroundApps])
        // A list the user reordered keeps its order; the new kind follows the kind before it.
        let reordered = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"priority":["timer","nowPlaying"]}"#.utf8)).normalized()
        #expect(reordered.priority.prefix(4) == [.timer, .agents, .messages, .nowPlaying])
    }

    @Test func appsCanBeTurnedOffOneByOne() throws {
        var m = MessageAlertSettings()
        // Until chosen: every app, except music apps, whose song pop-ups the island shows already.
        #expect(m.shows(app: "WhatsApp") && m.shows(app: "Calendar"))
        #expect(!m.shows(app: "Music") && !m.shows(app: "Spotify"))
        m.apps["Calendar"] = false
        m.apps["Music"] = true
        #expect(!m.shows(app: "Calendar") && m.shows(app: "Music") && m.shows(app: "WhatsApp"))
        // Kept across launches.
        var s = IslandSettings()
        s.messages = m
        #expect(IslandSettings.decode(s.encoded()).messages.apps == ["Calendar": false, "Music": true])
    }

    @Test func recentMessagesKeepTheNewestAndWhatsRead() {
        var recent = RecentMessages(limit: 3)
        for i in 1...4 { recent.add(MessageInfo(id: "\(i)", app: i % 2 == 0 ? "Slack" : "WhatsApp", sender: "S\(i)", text: "")) }
        // Newest first; past the limit the oldest go.
        #expect(recent.entries.map(\.id) == ["4", "3", "2"])
        #expect(recent.unreadCount == 3)
        // The same notification again moves up, unread, without a copy.
        recent.markRead(id: "2")
        recent.add(MessageInfo(id: "2", app: "Slack", sender: "S2", text: "edited"))
        #expect(recent.entries.map(\.id) == ["2", "4", "3"])
        #expect(recent.entries[0].message.text == "edited" && !recent.entries[0].read)
        // Opening Slack reads its messages, not WhatsApp's.
        recent.markRead(app: "Slack", bundleID: nil)
        #expect(recent.entries.filter { !$0.read }.map(\.id) == ["3"])
        recent.setLimit(1)
        #expect(recent.entries.map(\.id) == ["2"])
        recent.removeAll()
        #expect(recent.isEmpty)
    }

    @Test func recentMessageTimes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(IslandFormat.ago(now.addingTimeInterval(-20), from: now) == "now")
        #expect(IslandFormat.ago(now.addingTimeInterval(-4 * 60), from: now) == "4m")
        #expect(IslandFormat.ago(now.addingTimeInterval(-2 * 3600 - 59), from: now) == "2h")
        #expect(IslandFormat.ago(now.addingTimeInterval(-3 * 86400), from: now) == "3d")
    }

    @Test func recentMessagesSettings() throws {
        let s = IslandSettings()
        #expect(s.messages.keepRecent && s.messages.recentLimit == 20)
        // Saved before the option: on, with the default length.
        let old = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"messages":{"style":"stack"}}"#.utf8))
        #expect(old.messages.keepRecent && old.messages.recentLimit == 20)
        var t = IslandSettings()
        t.messages.recentLimit = 1000
        #expect(t.normalized().messages.recentLimit == MessageAlertSettings.recentLimitRange.upperBound)
        // The widget needs the module, like the others.
        #expect(DashboardWidgetKind.messages.module == .messages)
        t.dashboard = [DashboardItem(.messages, .medium)]
        t[module: .messages].enabled = false
        #expect(t.visibleDashboard.isEmpty)
    }

    @Test func batteryPercentShowsUntilTurnedOff() throws {
        #expect(IslandSettings().battery.showPercent)
        // Saved before the option: still shown, the other battery settings kept.
        let old = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"battery":{"alertOnPower":false}}"#.utf8))
        #expect(old.battery.showPercent && !old.battery.alertOnPower)
        var s = IslandSettings()
        s.battery.showPercent = false
        #expect(!IslandSettings.decode(s.encoded()).battery.showPercent)
    }

    @Test func eachStyleHasItsShape() {
        let m = MessageInfo(id: "1", app: "WhatsApp", sender: "Ama", text: "Hi")
        func size(_ style: MessageAlertStyle, _ list: [MessageInfo]) -> CGSize {
            IslandMetrics.alertSize(for: .messages(list, style), notch: notch)
        }
        // Ears and badges: like the AirPods alert, an icon in each ear.
        #expect(size(.ears, [m]) == CGSize(width: 185 + 2 * (16 + 20 + 14), height: 32))
        #expect(size(.badges, [m]) == size(.ears, [m]))
        #expect(IslandAlert(kind: .messages, style: .messages([m], .ears)).isCompact)
        // The ticker: wide ears, one line.
        #expect(size(.ticker, [m]).height == 32)
        #expect(size(.ticker, [m]).width > size(.ears, [m]).width + 100)
        // The card and the stack: cards below the notch; the stack grows a sliver per message behind it.
        #expect(!IslandAlert(kind: .messages, style: .messages([m], .card)).isCompact)
        #expect(size(.card, [m]) == IslandMetrics.messageCard)
        #expect(size(.stack, [m, m, m]).height == size(.stack, [m]).height + 12)
        #expect(size(.stack, [m, m, m, m, m]).height == size(.stack, [m, m, m]).height)
        #expect(IslandMetrics.messageListHeight(count: 3) > size(.stack, [m, m, m]).height)
    }

    @Test func unreadBadgesSitInTheEars() {
        let apps = [UnreadApp(app: "WhatsApp", count: 2, lastSender: "Ama"), UnreadApp(app: "Slack", count: 1, lastSender: "Kofi")]
        let ears = IslandMetrics.primaryEarWidths(.messages(apps))
        #expect(ears.leading == IslandMetrics.iconRowWidth(count: 2))
        #expect(ears.trailing > 0)
    }
}
