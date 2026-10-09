import IslandCore
import SwiftUI

/// A message on the island, in the style chosen in Settings › Messages: a
/// card, ears (the message drops down on hover), a ticker, a stack, or ears
/// that leave a badge behind. Pointing at it keeps it up; clicking opens the
/// conversation.
struct MessageAlertView: View {
    let messages: [MessageInfo]
    let style: MessageAlertStyle
    let model: IslandViewModel

    var body: some View {
        Group {
            switch style {
            case .card: card
            case .stack: if model.peekingMessages { list } else { stack }
            case .ears, .badges: ears
            case .ticker: ticker
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(messages.first.map { "\($0.app): \($0.sender), \(text($0))" } ?? "")
    }

    private var newest: MessageInfo { messages[0] }
    private var notchH: CGFloat { model.notch.rect.height }
    private var inset: CGFloat { IslandMetrics.shoulder + 14 }

    private func text(_ m: MessageInfo) -> String {
        model.settings.messages.hideText ? "New message" : (m.text.isEmpty ? m.context : m.text)
    }

    // MARK: card

    private var card: some View {
        VStack(spacing: 0) {
            appRow(trailing: Text("now").foregroundStyle(.secondary))
            HStack(alignment: .top, spacing: 10) {
                SenderCircle(message: newest, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    senderLine(newest)
                    Text(text(newest)).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, inset)
            .padding(.top, 2)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Spacer()
                IslandCapsuleButton(title: "Open") { openNewest() }
                IslandIconButton(systemName: "xmark", size: 24, label: "Dismiss") { model.env.engine.dismissAlert() }
            }
            .padding(.horizontal, inset - 2)
            .padding(.bottom, 9)
        }
        .padding(.horizontal, IslandMetrics.shoulder)
        .contentShape(Rectangle())
    }

    // MARK: stack

    private var stack: some View {
        VStack(spacing: 0) {
            appRow(trailing: Group {
                if messages.count > 1 {
                    Text("\(messages.count)").font(.system(size: 11, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 7).frame(minHeight: 16).background(Capsule().fill(.red)).foregroundStyle(.white)
                } else {
                    Text("now").foregroundStyle(.secondary)
                }
            })
            HStack(alignment: .top, spacing: 10) {
                SenderCircle(message: newest, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    senderLine(newest)
                    Text(text(newest)).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, inset)
            // The others, peeking out underneath.
            ForEach(0..<min(2, messages.count - 1), id: \.self) { i in
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                    .fill(.primary.opacity(0.16 - Double(i) * 0.06))
                    .frame(height: 5)
                    .padding(.horizontal, inset - 4 + CGFloat(i) * 8)
                    .padding(.top, i == 0 ? 6 : 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IslandMetrics.shoulder)
        .modifier(MediaHotspot(model: model, key: "alertIcon"))
    }

    /// The stack fanned out (on hover): a row per message; click one to open it.
    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(messages.count) new").foregroundStyle(.secondary)
                Spacer()
                Text("now").foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(height: notchH)
            .padding(.horizontal, inset)
            ForEach(messages) { m in
                Button { model.env.messages.open(m); model.env.engine.dismissAlert() } label: {
                    HStack(spacing: 8) {
                        MessageAppIcon(app: m.app, bundleID: m.bundleID, size: 18)
                        Text(m.sender).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                        Text(text(m)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, inset)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IslandMetrics.shoulder)
        .modifier(MediaHotspot(model: model, key: "title"))
    }

    // MARK: ears

    private var ears: some View {
        let notchW = model.notch.rect.width
        let ear = max(0, (model.bodySize.width - notchW) / 2)
        let inner = max(0, ear - IslandMetrics.earOuterPadding - IslandMetrics.earInnerGap)
        return VStack(spacing: 0) {
            if model.settings.compactStyle == .beside {
                HStack(spacing: 0) {
                    MessageAppIcon(app: newest.app, bundleID: newest.bundleID, size: IslandMetrics.glyph)
                        .modifier(MediaHotspot(model: model, key: "alertIcon"))
                        .frame(width: inner, alignment: .leading)
                        .padding(.leading, IslandMetrics.earOuterPadding)
                        .padding(.trailing, IslandMetrics.earInnerGap)
                    Color.clear.frame(width: notchW)
                    SenderCircle(message: newest, size: IslandMetrics.glyph)
                        .frame(width: inner, alignment: .trailing)
                        .padding(.leading, IslandMetrics.earInnerGap)
                        .padding(.trailing, IslandMetrics.earOuterPadding)
                }
                .frame(height: notchH)
            } else {
                Color.clear.frame(height: notchH)
                HStack(spacing: 8) {
                    MessageAppIcon(app: newest.app, bundleID: newest.bundleID, size: 18)
                        .modifier(MediaHotspot(model: model, key: "alertIcon"))
                    Text(newest.sender).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    SenderCircle(message: newest, size: 18)
                }
                .padding(.horizontal, 14)
                .frame(height: IslandMetrics.belowBand - 2)
            }
            if model.peekingMessages {
                // What they said, under the ears, like a song's title.
                VStack(alignment: .leading, spacing: 1) {
                    senderLine(newest)
                    MarqueeText(text: text(newest), font: .system(size: 11.5, weight: .medium), reduceMotion: model.reduceMotion)
                        .opacity(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IslandMetrics.earOuterPadding)
                .padding(.top, 2)
                .modifier(MediaHotspot(model: model, key: "title"))
                .transition(.peekRow)
            }
        }
        .padding(.horizontal, IslandMetrics.shoulder)
        .modifier(EarForeground(material: model.material))
    }

    // MARK: ticker

    private var ticker: some View {
        let notchW = model.notch.rect.width
        let ear = max(0, (model.bodySize.width - notchW) / 2)
        let inner = max(0, ear - IslandMetrics.earOuterPadding - 6)
        return Group {
            if model.settings.compactStyle == .beside {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        MessageAppIcon(app: newest.app, bundleID: newest.bundleID, size: 18)
                        Text(newest.sender).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    .frame(width: inner, alignment: .leading)
                    .padding(.leading, IslandMetrics.earOuterPadding)
                    .padding(.trailing, 6)
                    Color.clear.frame(width: notchW)
                    MarqueeText(text: text(newest), font: .system(size: 12.5), reduceMotion: model.reduceMotion)
                        .frame(width: inner)
                        .padding(.leading, 6)
                        .padding(.trailing, IslandMetrics.earOuterPadding)
                }
                .frame(height: notchH)
            } else {
                VStack(spacing: 0) {
                    Color.clear.frame(height: notchH)
                    HStack(spacing: 8) {
                        MessageAppIcon(app: newest.app, bundleID: newest.bundleID, size: 18)
                        Text(newest.sender).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                        MarqueeText(text: text(newest), font: .system(size: 12), reduceMotion: model.reduceMotion)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: IslandMetrics.belowBand - 2)
                }
            }
        }
        .padding(.horizontal, IslandMetrics.shoulder)
        .modifier(EarForeground(material: model.material))
    }

    // MARK: pieces

    /// The ears' row of a card: the app on the left, something on the right.
    private func appRow(trailing: some View) -> some View {
        HStack(spacing: 6) {
            MessageAppIcon(app: newest.app, bundleID: newest.bundleID, size: 16)
            Text(newest.app).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: model.notch.rect.width + 8)
            trailing
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(height: notchH)
        .padding(.horizontal, inset - IslandMetrics.shoulder)
    }

    private func senderLine(_ m: MessageInfo) -> some View {
        HStack(spacing: 4) {
            Text(m.sender).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if !m.context.isEmpty, !m.text.isEmpty {
                Text("· \(m.context)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func openNewest() {
        model.env.messages.open(newest)
        model.env.engine.dismissAlert()
    }
}

/// The app a message came from: its own icon, or its initial.
struct MessageAppIcon: View {
    let app: String
    let bundleID: String?
    var size: CGFloat = 20
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let icon = env.messages.icon(for: app, bundleID: bundleID) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color.accentColor)
                .frame(width: size, height: size)
                .overlay(Text(String(app.prefix(1))).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
        }
    }
}

/// The sender's initials in a circle, in a colour of their own.
struct SenderCircle: View {
    let message: MessageInfo
    var size: CGFloat = 20

    private static let colors: [Color] = [.pink, .orange, .purple, .teal, .indigo, .mint, .brown, .cyan]

    var body: some View {
        let hash = message.sender.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        Circle().fill(Self.colors[abs(hash) % Self.colors.count].gradient)
            .frame(width: size, height: size)
            .overlay(Text(message.initials).font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white))
    }
}

/// An app's icon with its unread count (the badges style). Clicking it opens
/// the app, unless it's part of a bigger button (`opens: false`).
struct UnreadBadgeIcon: View {
    let app: UnreadApp
    var size: CGFloat = IslandMetrics.glyph
    var opens = true
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if opens {
            Button { env.messages.openApp(name: app.app, bundleID: app.bundleID) } label: { badged }
                .buttonStyle(.plain)
                .help("\(app.app) · \(app.count) unread, last from \(app.lastSender)")
        } else {
            badged
        }
    }

    private var badged: some View {
        MessageAppIcon(app: app.app, bundleID: app.bundleID, size: size)
            .overlay(alignment: .topTrailing) { CountBadge(count: app.count).offset(x: 5, y: -4) }
    }
}

/// A red count, like an app's badge in the Dock.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 8.5, weight: .heavy)).monospacedDigit().foregroundStyle(.white)
            .lineLimit(1).fixedSize()   // its own width, not the icon's: "12", not "…"
            .padding(.horizontal, 3).frame(minWidth: 13, minHeight: 13)
            .background(Capsule().fill(.red).stroke(.black, lineWidth: 1.2))
            .allowsHitTesting(false)
    }
}

/// The unread messages opened from the compact island: each app, how many,
/// who wrote last; Open goes to the app.
struct MessagesExpanded: View {
    let apps: [UnreadApp]
    let model: IslandViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: model.notch.rect.height)
            ForEach(apps.prefix(3)) { app in
                HStack(spacing: 10) {
                    MessageAppIcon(app: app.app, bundleID: app.bundleID, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.app).font(.system(size: 13, weight: .semibold))
                        Text(app.count == 1 ? "1 message from \(app.lastSender)" : "\(app.count) messages, last from \(app.lastSender)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    IslandCapsuleButton(title: "Open") { model.env.messages.openApp(name: app.app, bundleID: app.bundleID); model.collapse() }
                }
                .frame(height: 36)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Mark all read") { model.env.messages.clearAll(); model.collapse() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 18)
    }
}

// MARK: recent messages

/// The dashboard's messages button, with how many recent messages are unread.
struct RecentMessagesButton: View {
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let unread = env.messages.recent.unreadCount
        IslandIconButton(systemName: unread > 0 ? "message.fill" : "message", size: 24,
                         label: unread > 0 ? "Messages, \(unread) unread" : "Messages") { model.openRecentMessages() }
            .overlay(alignment: .topTrailing) {
                if unread > 0 { CountBadge(count: unread).offset(x: 4, y: -2) }
            }
    }
}

/// The messages that reached the island lately, newest first; click one to
/// open its conversation. They stay until the app quits (Settings › Notifications).
struct RecentMessagesView: View {
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let messages = env.messages
        let entries = messages.recent.entries
        let unread = messages.recent.unreadCount
        VStack(spacing: 0) {
            EarRow(model: model) {
                // As much as fits beside the camera.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Image(systemName: "message.fill").foregroundStyle(.green)
                        Text("Messages").fixedSize()
                        if unread > 0 { Text("\(unread) new").foregroundStyle(.secondary).fixedSize() }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "message.fill").foregroundStyle(.green)
                        Text("Messages").fixedSize()
                    }
                    Image(systemName: "message.fill").foregroundStyle(.green)
                }
            } trailing: {
                if unread > 0 {
                    IslandIconButton(systemName: "checkmark.circle", size: 26, label: "Mark all as read") {
                        withAnimation(.snappy) { messages.markAllRecentRead() }
                    }
                }
                if !entries.isEmpty {
                    IslandIconButton(systemName: "trash", size: 26, label: "Clear the list") {
                        withAnimation(.snappy) { messages.clearRecent() }
                    }
                }
            }
            Group {
                if !model.settings.messages.keepRecent {
                    RecentMessagesPlaceholder(text: "Recent messages are off", turnOn: true)
                } else if entries.isEmpty {
                    RecentMessagesPlaceholder(text: "No messages yet. Those that reach the island stay here until you quit.", turnOn: false)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                RecentMessageRow(entry: entry, model: model, compact: false)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .padding(.horizontal, IslandMetrics.shoulder)
    }
}

/// The dashboard widget: the newest few, and the way to the rest.
struct MessagesWidget: View {
    let size: WidgetSize
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let entries = env.messages.recent.entries
        if !model.settings.messages.keepRecent {
            RecentMessagesPlaceholder(text: "Recent messages are off", turnOn: true)
        } else if entries.isEmpty {
            RecentMessagesPlaceholder(text: "Messages that reach the island show up here", turnOn: false)
        } else {
            // Three rows fit; with more, the third is the way to all of them.
            let shown = entries.count > 3 ? 2 : 3
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries.prefix(shown)) { entry in
                    RecentMessageRow(entry: entry, model: model, compact: true)
                }
                if entries.count > shown {
                    Button { model.openRecentMessages() } label: {
                        HStack(spacing: 4) {
                            Text("See all \(entries.count)")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, -6)
            Spacer(minLength: 0)
        }
    }
}

private struct RecentMessagesPlaceholder: View {
    let text: String
    let turnOn: Bool
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 8) {
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if turnOn { IslandCapsuleButton(title: "Turn On") { env.settings.settings.messages.keepRecent = true } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One recent message: unread dot, app, sender, when, and what they said.
/// Click to open the conversation; point at it to remove it from the list.
struct RecentMessageRow: View {
    let entry: RecentMessages.Entry
    let model: IslandViewModel
    var compact = false
    @Environment(AppEnvironment.self) private var env
    @State private var hovering = false

    var body: some View {
        let m = entry.message
        let text = model.settings.messages.hideText ? "New message" : (m.text.isEmpty ? m.context : m.text)
        Button {
            env.messages.open(m)
            model.collapse()
        } label: {
            HStack(alignment: compact ? .center : .top, spacing: compact ? 6 : 9) {
                Circle().fill(.blue).frame(width: 6, height: 6)
                    .opacity(entry.read ? 0 : 1)
                    .padding(.top, compact ? 0 : 10)
                MessageAppIcon(app: m.app, bundleID: m.bundleID, size: compact ? 18 : 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(m.sender).font(.system(size: compact ? 11.5 : 12.5, weight: .semibold)).lineLimit(1)
                        if !compact, !m.context.isEmpty, !m.text.isEmpty {
                            Text("· \(m.context)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        TimelineView(.everyMinute) { t in
                            Text(IslandFormat.ago(m.date, from: t.date))
                        }
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                        .opacity(hovering && !compact ? 0 : 1)
                    }
                    Text(text).font(.system(size: compact ? 11 : 12)).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                }
                .opacity(entry.read ? 0.7 : 1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, compact ? 3 : 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Beside the button, not inside it: a button in a button doesn't click.
        .overlay(alignment: .topTrailing) {
            if hovering && !compact {
                IslandIconButton(systemName: "xmark", size: 20, label: "Remove from the list") {
                    withAnimation(.snappy) { env.messages.removeRecent(m.id) }
                }
                .padding(.top, 3).padding(.trailing, 2)
            }
        }
        .onHover { hovering = $0 }
        .help("Open in \(m.app)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.read ? "" : "Unread. ")\(m.app), \(m.sender): \(text)")
    }
}
