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
    let audioLevels: AudioLevelService
    let lyrics: LyricsService
    let systemStats: SystemStatsService
    let shelf: ShelfService
    let downloads: DownloadsService
    let privacy: PrivacyIndicatorService
    let devices: DevicesService
    let messages: MessageAlertsService
    let hud: HUDService
    let weather: WeatherService
    let clipboard: ClipboardService
    let shortcuts: ShortcutsService
    let fullScreen: FullScreenMonitor
    let lock: LockMonitor
    let updates: UpdateService

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
        audioLevels = AudioLevelService()
        lyrics = LyricsService(settings: settings)
        systemStats = SystemStatsService(settings: settings)
        shelf = ShelfService()
        downloads = DownloadsService(settings: settings, engine: engine)
        privacy = PrivacyIndicatorService(settings: settings)
        devices = DevicesService(settings: settings, engine: engine)
        messages = MessageAlertsService(settings: settings, engine: engine)
        hud = HUDService(settings: settings, engine: engine, audio: audioOutput)
        weather = WeatherService(settings: settings)
        clipboard = ClipboardService(settings: settings)
        shortcuts = ShortcutsService()
        fullScreen = FullScreenMonitor()
        lock = LockMonitor()
        updates = UpdateService(engine: engine)
        let providers: [ActivityProvider] = [nowPlaying, timers, battery, calendar, backgroundApps, shelf, downloads, privacy]
        providers.forEach(engine.register)
    }

    func start() {
        nowPlaying.start()
        battery.start()
        calendar.start()
        backgroundApps.start()
        audioOutput.start()
        hud.start()
        messages.start()
        fullScreen.start()
        lock.start()
        updates.start()
        clipboard.start()
        shortcuts.reload()
        // Modules that ask for permission start only when they're on.
        whenChanged({ [settings] in settings.settings[module: .downloads].enabled }) { [weak self] on in
            on ? self?.downloads.start() : self?.downloads.stop()
        }
        whenChanged({ [settings] in settings.settings[module: .devices].enabled }) { [weak self] on in
            if on { self?.devices.start() }
        }
        whenChanged({ [settings] in settings.settings.dashboard.map(\.kind.rawValue) }) { [weak self] _ in
            self?.weather.updateDemand()
        }
        let s = settings.settings
        if s[module: .downloads].enabled { downloads.start() }
        if s[module: .devices].enabled { devices.start() }
        if s[module: .privacy].enabled { privacy.start() }
        weather.updateDemand()
    }

    func stop() {
        nowPlaying.stop()
        downloads.stop()
    }
}
