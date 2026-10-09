import Foundation
import IslandCore
import Observation

/// Lyrics from LRCLIB (lrclib.net), a free community database of synced lyrics.
/// Only asked when the lyrics page is opened, and only with the track's
/// title, artist, album and length. Results are cached for the session.
@Observable
final class LyricsService {
    enum State: Equatable {
        case idle, loading, loaded(Lyrics), notFound, disabled
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var trackKey: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var cache: [String: State] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    static func key(for info: NowPlayingInfo) -> String { "\(info.artist)|\(info.title)" }

    func load(for info: NowPlayingInfo) {
        guard settings.settings.nowPlaying.lyricsEnabled else { state = .disabled; return }
        let key = Self.key(for: info)
        guard key != trackKey || state == .idle else { return }
        trackKey = key
        task?.cancel()
        if let cached = cache[key] { state = cached; return }
        state = .loading
        task = Task { [weak self] in
            let result = await Self.fetch(info)
            guard !Task.isCancelled, let self, self.trackKey == key else { return }
            if case .failed = result {} else { self.cache[key] = result }
            self.state = result
            switch result {
            case .loaded(let l): Log.info("lyrics: \(l.synced.count) synced lines, plain \(l.plain != nil) for \(key)")
            default: Log.info("lyrics: \(result) for \(key)")
            }
        }
    }

    // MARK: LRCLIB

    private struct Track: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    nonisolated private static func fetch(_ info: NowPlayingInfo) async -> State {
        do {
            if let t = try await get(title: info.title, artist: info.artist, album: info.album, duration: info.duration) {
                return state(from: t)
            }
            // Titles like "Song (feat. X)" often match only without the suffix.
            let cleaned = info.title.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            let results = try await search(title: cleaned, artist: info.artist)
            let best = results.min { a, b in
                abs((a.duration ?? 0) - (info.duration ?? 0)) < abs((b.duration ?? 0) - (info.duration ?? 0))
            }
            return best.map(state(from:)) ?? .notFound
        } catch {
            return .failed("Couldn't reach LRCLIB")
        }
    }

    nonisolated private static func state(from t: Track) -> State {
        if t.instrumental == true { return .loaded(Lyrics(synced: [], plain: nil, instrumental: true)) }
        let synced = LyricsParser.parseLRC(t.syncedLyrics ?? "")
        let plain = t.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !synced.isEmpty || !(plain ?? "").isEmpty else { return .notFound }
        return .loaded(Lyrics(synced: synced, plain: plain))
    }

    nonisolated private static func request(_ path: String, _ items: [URLQueryItem]) -> URLRequest? {
        var c = URLComponents(string: "https://lrclib.net")!
        c.path = path
        c.queryItems = items
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 8)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    /// LRCLIB asks clients to say who they are: the app, its version and where it lives.
    nonisolated private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "DynamicIsland/\(version) (macOS app; https://github.com/manu-tech-code/dynamic-island)"
    }()

    nonisolated private static func get(title: String, artist: String, album: String, duration: Double?) async throws -> Track? {
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let d = duration { items.append(URLQueryItem(name: "duration", value: String(Int(d.rounded())))) }
        guard let req = request("/api/get", items) else { return nil }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Track.self, from: data)
    }

    nonisolated private static func search(title: String, artist: String) async throws -> [Track] {
        guard let req = request("/api/search", [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)])
        else { return [] }
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }
}
