import AppKit
import Combine
import SwiftUI

/// A borderless panel above the menu bar, centred on the notch. It takes
/// clicks only while the pointer is over the island, so the menu bar and
/// windows underneath keep working everywhere else.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    private let model = IslandModel()
    private var panel: IslandPanel?
    private var screen: NSScreen?
    private var pointerTimer: Timer?
    private var leaveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Room for the expanded island and its shadow.
    private static let panelSize = CGSize(width: 720, height: 320)

    func start() {
        buildPanel()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildPanel() }
        }
        NowPlaying.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the value lands.
                DispatchQueue.main.async { self?.model.syncWithMusic() }
            }
            .store(in: &cancellables)
        // Twenty checks a second of where the pointer is: cheap, and works
        // whether or not the panel is taking events at the moment.
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        model.syncWithMusic()
    }

    /// The built-in display, which has the notch; otherwise the main one.
    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func buildPanel() {
        guard let screen = Self.notchScreen() else { return }
        self.screen = screen
        let inset = screen.safeAreaInsets.top
        if inset > 0,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            model.hasNotch = true
            model.notchSize = CGSize(width: screen.frame.width - left - right, height: inset)
        } else {
            model.hasNotch = false
            model.notchSize = CGSize(width: 190, height: max(NSStatusBar.system.thickness, 24))
        }

        let size = Self.panelSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        if let panel {
            panel.setFrame(frame, display: true)
            return
        }
        let panel = IslandPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = ClickThroughHostingView(rootView: IslandRootView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// The island's rectangle on screen, a little padded.
    private func islandRect(padding: CGFloat) -> NSRect? {
        guard let screen else { return nil }
        let size = model.currentSize
        return NSRect(x: screen.frame.midX - size.width / 2 - padding,
                      y: screen.frame.maxY - size.height - padding,
                      width: size.width + 2 * padding, height: size.height + padding)
    }

    private func trackPointer() {
        guard let panel, let rect = islandRect(padding: model.state == .expanded ? 8 : 4) else { return }
        let inside = model.state != .idle && rect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        if inside {
            leaveTask?.cancel()
            leaveTask = nil
            if !model.hovering {
                model.hovering = true
                if model.state == .compact, Settings.shared.haptics {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
        } else if model.hovering, leaveTask == nil {
            // A short grace period, so a pointer skimming the edge does not
            // fold the player away.
            let delay = model.state == .expanded ? 350 : 60
            leaveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.model.hovering = false
                self.model.collapse()
                self.leaveTask = nil
            }
        }
    }
}
