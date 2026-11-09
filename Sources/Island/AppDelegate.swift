import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let notch = NotchController()
    private let lockScreen = LockScreenPlayer()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NowPlaying.shared.start()
        notch.start()
        lockScreen.start()
        buildStatusItem()
        Settings.shared.$hidesMenuBarIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hidden in self?.statusItem?.isVisible = !hidden }
            .store(in: &cancellables)
    }

    /// Opening the app again (Finder, Spotlight) brings the icon back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Settings.shared.hidesMenuBarIcon = false
        return true
    }

    // MARK: Menu

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Island")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = !Settings.shared.hidesMenuBarIcon
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = Settings.shared
        let music = NowPlaying.shared
        let header = NSMenuItem(title: music.hasTrack ? "\(music.title) — \(music.artist)" : "Nothing playing",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(toggle("Liquid Glass", settings.liquidGlass) { settings.liquidGlass.toggle() })
        let darkness = NSMenuItem(title: "Glass Darkness", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in [0.0, 0.15, 0.3, 0.45, 0.6] {
            sub.addItem(toggle("\(Int(value * 100))%", abs(settings.glassTint - value) < 0.01) { settings.glassTint = value })
        }
        darkness.submenu = sub
        menu.addItem(darkness)
        menu.addItem(toggle("Trackpad Haptics", settings.haptics) { settings.haptics.toggle() })
        menu.addItem(.separator())
        menu.addItem(toggle("Lock Screen Player", settings.lockScreenPlayer) { settings.lockScreenPlayer.toggle() })
        menu.addItem(toggle("Artwork Background", settings.lockScreenArtwork) { settings.lockScreenArtwork.toggle() })
        menu.addItem(.separator())
        menu.addItem(toggle("Launch at Login", settings.launchesAtLogin) { settings.launchesAtLogin.toggle() })
        let hide = ActionItem(title: "Hide Menu Bar Icon") { settings.hidesMenuBarIcon = true }
        hide.toolTip = "Open Island again from Finder or Spotlight to bring it back."
        menu.addItem(hide)
        menu.addItem(.separator())
        menu.addItem(ActionItem(title: "Quit Island", key: "q") { NSApp.terminate(nil) })
    }

    private func toggle(_ title: String, _ on: Bool, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ActionItem(title: title, action: action)
        item.state = on ? .on : .off
        return item
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, key: String = "", action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        MainActor.assumeIsolated { handler() }
    }
}
