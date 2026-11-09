import AppKit
import ServiceManagement

/// Everything the person can change, kept in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// The open island uses Liquid Glass (macOS 26) instead of black.
    @Published var liquidGlass: Bool { didSet { defaults.set(liquidGlass, forKey: "liquidGlass") } }
    /// How dark the glass is tinted, 0...0.8.
    @Published var glassTint: Double { didSet { defaults.set(glassTint, forKey: "glassTint") } }
    /// Trackpad haptic when the pointer reaches the island.
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    /// Now-playing screen on the lock screen.
    @Published var lockScreenPlayer: Bool { didSet { defaults.set(lockScreenPlayer, forKey: "lockScreenPlayer") } }
    /// The zoomed artwork fills the lock screen behind the player.
    @Published var lockScreenArtwork: Bool { didSet { defaults.set(lockScreenArtwork, forKey: "lockScreenArtwork") } }
    /// The menu bar icon is hidden; opening the app again shows it.
    @Published var hidesMenuBarIcon: Bool { didSet { defaults.set(hidesMenuBarIcon, forKey: "hidesMenuBarIcon") } }

    private init() {
        defaults.register(defaults: [
            "liquidGlass": true,
            "glassTint": 0.3,
            "haptics": true,
            "lockScreenPlayer": true,
            "lockScreenArtwork": true,
            "hidesMenuBarIcon": false,
        ])
        liquidGlass = defaults.bool(forKey: "liquidGlass")
        glassTint = defaults.double(forKey: "glassTint")
        haptics = defaults.bool(forKey: "haptics")
        lockScreenPlayer = defaults.bool(forKey: "lockScreenPlayer")
        lockScreenArtwork = defaults.bool(forKey: "lockScreenArtwork")
        hidesMenuBarIcon = defaults.bool(forKey: "hidesMenuBarIcon")
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Island: launch at login change failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}
