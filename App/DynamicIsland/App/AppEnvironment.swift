import AppKit
import IslandCore
import Observation

/// Owns every long-lived service. Views reach it through the SwiftUI environment.
@Observable
final class AppEnvironment {
    let settings: SettingsStore
    let look: SystemLook
    let engine: ActivityEngine
    let nowPlaying: NowPlayingService
    let timers: TimerService
    let battery: BatteryService
    let calendar: CalendarService
    let backgroundApps: BackgroundAppsService
    let audioOutput: AudioOutputService
    let lyrics: LyricsService
    let systemStats: SystemStatsService

    @ObservationIgnored var openSettings: () -> Void = {}

    init() {
        let settings = SettingsStore()
        let engine = ActivityEngine(settings: settings)
        self.settings = settings
        self.engine = engine
        look = SystemLook()
        nowPlaying = NowPlayingService(settings: settings)
        timers = TimerService(settings: settings, engine: engine)
        battery = BatteryService(settings: settings, engine: engine)
        calendar = CalendarService(settings: settings, engine: engine)
        backgroundApps = BackgroundAppsService(settings: settings)
        audioOutput = AudioOutputService()
        lyrics = LyricsService(settings: settings)
        systemStats = SystemStatsService(settings: settings)
        [nowPlaying, timers, battery, calendar, backgroundApps].forEach(engine.register)
    }

    func start() {
        nowPlaying.start()
        battery.start()
        calendar.start()
        backgroundApps.start()
        audioOutput.start()
    }

    func stop() {
        nowPlaying.stop()
    }
}
