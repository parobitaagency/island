import AppKit
import Combine
import SkyLightWindow
import SwiftUI

/// An iPhone-style now-playing screen on the lock screen: the artwork zoomed
/// to fill the screen, a clock, and a glass player card in front.
///
/// The windows join the SkyLight space that sits above the lock screen. The
/// background takes no clicks or keys, so the password and Touch ID keep
/// working, and it fades out at the bottom where macOS shows them.
private final class LockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect, level: NSWindow.Level, clickThrough: Bool) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = clickThrough
        self.level = level
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        alphaValue = 0
    }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private enum SkyLight {
    typealias RemoveWindows = @convention(c) (Int32, CFArray, CFArray) -> Int32
    static let remove: RemoveWindows? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let symbol = dlsym(handle, "SLSRemoveWindowsFromSpaces") else { return nil }
        return unsafeBitCast(symbol, to: RemoveWindows.self)
    }()

    @MainActor static func add(_ window: NSWindow) {
        SkyLightOperator.shared.delegateWindow(window)
    }

    @MainActor static func removeFromSky(_ window: NSWindow) {
        let sky = SkyLightOperator.shared
        _ = remove?(sky.connection, [window.windowNumber] as CFArray, [sky.space] as CFArray)
    }
}

@MainActor
final class LockScreenPlayer {
    private var background: LockPanel?
    private var card: LockPanel?
    private var isLocked = false
    private var cancellables = Set<AnyCancellable>()

    static let cardSize = CGSize(width: 440, height: 196)

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLocked = true
                NowPlaying.shared.refresh()
                self?.update()
            }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLocked = false
                self?.update()
            }
        }
        NowPlaying.shared.$source
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        Settings.shared.$lockScreenPlayer.combineLatest(Settings.shared.$lockScreenArtwork)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.hide(animated: false)
                DispatchQueue.main.async { self?.update() }
            }
            .store(in: &cancellables)
    }

    private var shouldShow: Bool {
        isLocked && Settings.shared.lockScreenPlayer && NowPlaying.shared.source != nil
    }

    private func update() {
        if shouldShow { show() } else { hide(animated: isLocked) }
    }

    private func show() {
        guard card == nil, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let frame = screen.frame

        if Settings.shared.lockScreenArtwork {
            let window = LockPanel(frame: frame, level: .mainMenu + 1, clickThrough: true)
            window.contentView = NSHostingView(rootView: LockBackground(music: .shared))
            window.setFrame(frame, display: false)
            present(window)
            background = window
        }

        let size = Self.cardSize
        let cardFrame = NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.36,
                               width: size.width, height: size.height)
        let window = LockPanel(frame: cardFrame, level: .mainMenu + 2, clickThrough: false)
        window.contentView = FirstClickHostingView(rootView: LockCard(music: .shared))
        window.setFrame(cardFrame, display: false)
        present(window)
        card = window
    }

    private func present(_ window: LockPanel) {
        window.orderFrontRegardless()
        SkyLight.add(window)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            window.animator().alphaValue = 1
        }
    }

    private func hide(animated: Bool) {
        for window in [background, card].compactMap({ $0 }) {
            let finish = {
                SkyLight.removeFromSky(window)
                window.orderOut(nil)
                window.close()
            }
            if animated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    window.animator().alphaValue = 0
                }, completionHandler: { MainActor.assumeIsolated(finish) })
            } else {
                finish()
            }
        }
        background = nil
        card = nil
    }
}

// MARK: - Views

private struct LockBackground: View {
    @ObservedObject var music: NowPlaying

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image = music.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                }
                LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.25)],
                               startPoint: .top, endPoint: .bottom)
                LockClock()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, proxy.size.height * 0.08)
            }
            .animation(.easeInOut(duration: 0.45), value: music.artwork.map(ObjectIdentifier.init))
            .mask(
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.70),
                    .init(color: .clear, location: 0.88),
                ], startPoint: .top, endPoint: .bottom)
            )
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

private struct LockClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 2) {
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 104, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 2)
        }
    }
}

private struct LockCard: View {
    @ObservedObject var music: NowPlaying

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Artwork(image: music.artwork, size: 64, corner: 12)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text(music.artist)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ProgressBar(music: music)
            Controls(music: music, large: true)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(width: LockScreenPlayer.cardSize.width, height: LockScreenPlayer.cardSize.height)
        .background(cardBackground)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(.black.opacity(0.15)), in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}
