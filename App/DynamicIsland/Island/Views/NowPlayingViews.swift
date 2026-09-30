import AppKit
import IslandCore
import SwiftUI

/// Expanded Now Playing: the player, or (taller) lyrics / Up Next under a mini player.
struct NowPlayingExpanded: View {
    let info: NowPlayingInfo
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let np = env.nowPlaying
        let tint = np.artworkColor.map(Color.init(nsColor:)) ?? .pink
        EarRow(model: model) {
            Image(systemName: "music.note").foregroundStyle(tint)
            Text(np.sourceApp?.localizedName ?? "Now Playing").lineLimit(1)
        } trailing: {
            Waveform(playing: info.isPlaying, color: tint)
        }
        if model.nowPlayingPage == .player {
            PlayerPage(info: info, model: model)
        } else {
            DetailPage(info: info, model: model)
        }
    }
}

// MARK: player

private struct PlayerPage: View {
    let info: NowPlayingInfo
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let np = env.nowPlaying
        Group {
            if model.isNarrow { narrow } else { wide }
        }
        .onAppear { np.wantQueue() }
        .onDisappear { np.releaseQueue() }
    }

    /// Standard width: controls beside the title.
    @ViewBuilder private var wide: some View {
        HStack(spacing: 14) {
            artwork(80, radius: 18)
            titles(size: 16)
            Spacer(minLength: 8)
            TransportControls(info: info, sizes: (34, 44))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        Spacer(minLength: 0)
        HStack(spacing: 8) {
            PositionRow(info: info)
            accessories
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
    }

    /// Narrow: controls move under the title so nothing is squeezed or cut.
    @ViewBuilder private var narrow: some View {
        HStack(spacing: 12) {
            artwork(64, radius: 14)
            titles(size: 15)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        Spacer(minLength: 0)
        PositionRow(info: info)
            .padding(.horizontal, 18)
        HStack(spacing: 4) {
            TransportControls(info: info, sizes: (30, 38))
            Spacer(minLength: 4)
            accessories
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func artwork(_ size: CGFloat, radius: CGFloat) -> some View {
        let np = env.nowPlaying
        return Button { np.openSourceApp() } label: {
            ArtworkView(image: np.artwork, size: size, radius: radius)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .help("Open \(np.sourceApp?.localizedName ?? "player")")
    }

    private func titles(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.title).font(.system(size: size, weight: .semibold)).lineLimit(1)
            Text([info.artist, info.album].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: size - 3)).foregroundStyle(.secondary).lineLimit(1)
            if model.settings.nowPlaying.showUpNext, let next = env.nowPlaying.queue?.upNext {
                Text("Up next · \(next.title)")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
                    .padding(.top, 2)
            }
        }
    }

    private var accessories: some View {
        HStack(spacing: 2) {
            IslandIconButton(systemName: "quote.bubble", size: 28, label: "Lyrics") { model.showPage(.lyrics) }
            IslandIconButton(systemName: "list.bullet", size: 28, label: "Up Next") { model.showPage(.upNext) }
            OutputButton(model: model)
        }
    }
}

private struct TransportControls: View {
    let info: NowPlayingInfo
    let sizes: (CGFloat, CGFloat)
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let np = env.nowPlaying
        HStack(spacing: 4) {
            IslandIconButton(systemName: "backward.fill", size: sizes.0, label: "Previous track") { np.previous() }
            IslandIconButton(systemName: info.isPlaying ? "pause.fill" : "play.fill", size: sizes.1, label: info.isPlaying ? "Pause" : "Play") { np.togglePlayPause() }
                .contentTransition(.symbolEffect(.replace))
            IslandIconButton(systemName: "forward.fill", size: sizes.0, label: "Next track") { np.next() }
        }
    }
}

private struct PositionRow: View {
    let info: NowPlayingInfo
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TimelineView(.periodic(from: .now, by: info.isPlaying ? 1 : 3600)) { ctx in
            let elapsed = info.elapsed(at: ctx.date) ?? 0
            let duration = info.duration ?? 0
            HStack(spacing: 10) {
                Text(IslandFormat.position(elapsed)).monospacedDigit()
                SeekBar(fraction: duration > 0 ? elapsed / duration : 0) { f in
                    if duration > 0 { env.nowPlaying.seek(to: f * duration) }
                }
                Text("−" + IslandFormat.position(max(0, duration - elapsed))).monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .opacity(duration > 0 ? 1 : 0)
        }
    }
}

struct SeekBar: View {
    let fraction: Double
    let onSeek: (Double) -> Void
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            ProgressTrack(fraction: fraction, height: hovering ? 7 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    onSeek(max(0, min(1, p.x / max(1, geo.size.width))))
                }
        }
        .frame(height: 14)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
    }
}

// MARK: lyrics / up next

private struct DetailPage: View {
    let info: NowPlayingInfo
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let np = env.nowPlaying
        HStack(spacing: 12) {
            ArtworkView(image: np.artwork, size: 44, radius: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(info.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            TransportControls(info: info, sizes: (28, 34))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        HStack(spacing: 6) {
            PageTab(title: "Lyrics", symbol: "quote.bubble", selected: model.nowPlayingPage == .lyrics) { model.showPage(.lyrics) }
            PageTab(title: "Up Next", symbol: "list.bullet", selected: model.nowPlayingPage == .upNext) { model.showPage(.upNext) }
            Spacer()
            OutputButton(model: model)
            IslandIconButton(systemName: "chevron.up", size: 28, label: "Back to player") { model.showPage(.player) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        Group {
            if model.nowPlayingPage == .lyrics { LyricsPage(info: info) } else { UpNextPage() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }
}

private struct PageTab: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(.primary.opacity(selected ? 0.16 : (hovering ? 0.08 : 0))))
                .foregroundStyle(selected ? .primary : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct LyricsPage: View {
    let info: NowPlayingInfo
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            switch env.lyrics.state {
            case .loaded(let lyrics) where lyrics.instrumental:
                Message(symbol: "music.note", title: "Instrumental")
            case .loaded(let lyrics) where !lyrics.synced.isEmpty:
                SyncedLyrics(lyrics: lyrics, info: info)
            case .loaded(let lyrics):
                ScrollView(showsIndicators: false) {
                    Text(lyrics.plain ?? "").font(.system(size: 15, weight: .medium)).lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                }
            case .idle, .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking up lyrics…").foregroundStyle(.secondary) }
            case .notFound:
                Message(symbol: "text.bubble", title: "No lyrics found for this song")
            case .disabled:
                VStack(spacing: 8) {
                    Message(symbol: "quote.bubble", title: "Lyrics are off")
                    IslandCapsuleButton(title: "Turn On") {
                        env.settings.settings.nowPlaying.lyricsEnabled = true
                        env.lyrics.load(for: info)
                    }
                }
            case .failed(let message):
                VStack(spacing: 8) {
                    Message(symbol: "wifi.exclamationmark", title: message)
                    IslandCapsuleButton(title: "Try Again") { env.lyrics.load(for: info) }
                }
            }
        }
        .onAppear { env.lyrics.load(for: info) }
        .onChange(of: LyricsService.key(for: info)) { env.lyrics.load(for: info) }
    }
}

private struct SyncedLyrics: View {
    let lyrics: Lyrics
    let info: NowPlayingInfo
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let current = lyrics.currentIndex(at: (info.elapsed(at: ctx.date) ?? 0) + 0.2)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(lyrics.synced) { line in
                            let isCurrent = line.id == current
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: isCurrent ? 19 : 16, weight: isCurrent ? .bold : .semibold))
                                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                .opacity(current.map { abs($0 - line.id) > 3 ? 0.45 : 1 } ?? 0.7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { env.nowPlaying.seek(to: line.time) }
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 70)
                    .animation(.smooth(duration: 0.35), value: current)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                             .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: current) { _, new in
                    guard let new else { return }
                    withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(new, anchor: .center) }
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("Lyrics from LRCLIB").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
        }
    }
}

private struct UpNextPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let np = env.nowPlaying
        Group {
            if let q = np.queue {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(q.playable ? "Playing from \(q.playlist)" : "Up Next").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text("\(q.currentIndex) of \(q.total)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 1) {
                                ForEach(q.tracks) { t in
                                    QueueRow(track: t, isCurrent: t.index == q.currentIndex, isPast: t.index < q.currentIndex, playable: q.playable)
                                        .id(t.index)
                                        .onTapGesture { np.playQueueTrack(t) }
                                }
                            }
                        }
                        .onAppear { proxy.scrollTo(q.currentIndex, anchor: .top) }
                    }
                }
            } else if np.queueLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading Up Next…").foregroundStyle(.secondary) }
            } else {
                Message(symbol: "list.bullet", title: "No Up Next from \(np.sourceApp?.localizedName ?? "this app")",
                        subtitle: "This player doesn't share its queue with other apps.")
            }
        }
        .onAppear { np.wantQueue() }
        .onDisappear { np.releaseQueue() }
    }
}

private struct QueueRow: View {
    let track: QueueTrack
    let isCurrent: Bool
    let isPast: Bool
    var playable = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isCurrent {
                    Image(systemName: "waveform").foregroundStyle(.pink)
                } else {
                    Text("\(track.index)").monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(IslandFormat.position(track.duration)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .opacity(isPast ? 0.5 : 1)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(isCurrent ? 0.12 : (hovering && playable ? 0.07 : 0))))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(isCurrent ? "Playing now" : playable ? "Play \(track.title)" : track.title)
    }
}

private struct Message: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: output picker

/// Opens a native menu: volume, Mac outputs (speakers, headphones, AirPods,
/// displays) and, while Music plays, Music's AirPlay speakers.
struct OutputButton: View {
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        IslandIconButton(systemName: "airplayaudio", size: 28,
                         label: "Output: \(env.audioOutput.current?.name ?? "Sound output")") {
            Task { await showMenu() }
        }
    }

    private func showMenu() async {
        let audio = env.audioOutput
        audio.refresh()
        let airPlay = env.nowPlaying.isMusicSource ? await MusicScripting.airPlayDevices() : []
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: "Volume"))
        if let v = audio.volume {
            let item = NSMenuItem()
            item.view = VolumeSliderView(value: v) { audio.setVolume($0) }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Output"))
        for d in audio.devices {
            menu.addItem(ClosureMenuItem.make(title: d.name, symbol: d.symbolName, checked: d.id == audio.defaultID) { audio.select(d) })
        }
        if !airPlay.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "AirPlay in Music"))
            for d in airPlay {
                menu.addItem(ClosureMenuItem.make(title: d.name, symbol: d.symbolName, checked: d.selected) {
                    Task { await MusicScripting.setAirPlay(d.name, selected: !d.selected) }
                })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem.make(title: "Sound Settings…", symbol: nil, checked: false) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
        })
        model.presentMenu(menu)
    }
}

/// Menu items that run a closure. Item targets are weak, so the target object
/// is also stored in `representedObject` to keep it alive.
enum ClosureMenuItem {
    final class Action: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    static func make(title: String, symbol: String?, checked: Bool, handler: @escaping () -> Void) -> NSMenuItem {
        let action = Action(handler)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.state = checked ? .on : .off
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}

/// Volume row for the output menu. Auto Layout pins the slider between the
/// two speaker icons and gives it a real width; the view stretches with the menu.
final class VolumeSliderView: NSView {
    private let onChange: (Float) -> Void
    private let slider: NSSlider

    init(value: Float, onChange: @escaping (Float) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: Double(value), minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 34))
        autoresizingMask = [.width]
        let low = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Quiet")!)
        let high = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Loud")!)
        [low, high].forEach { $0.contentTintColor = .secondaryLabelColor }
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.setAccessibilityLabel("Volume")
        for v in [low, slider, high] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            low.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            low.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: low.trailingAnchor, constant: 10),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            high.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 10),
            high.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            high.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func changed() { onChange(slider.floatValue) }
}
