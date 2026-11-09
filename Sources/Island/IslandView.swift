import AppKit
import SwiftUI

/// The notch outline: small outward flares at the top corners that meet the
/// menu bar, rounded corners at the bottom. Both radii animate, so the
/// outline morphs in one piece instead of snapping.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let bottom = min(bottomRadius, (rect.width - 2 * top) / 2, rect.height - top)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

enum IslandState: Equatable {
    /// Nothing playing: exactly the hardware notch.
    case idle
    /// Artwork on the left, waveform on the right.
    case compact
    /// The full player.
    case expanded
}

/// Shared between the window controller and the view.
@MainActor
final class IslandModel: ObservableObject {
    @Published var state: IslandState = .idle
    @Published var hovering = false
    /// The real notch, in points. A Mac without one gets a pill this size.
    var notchSize = CGSize(width: 190, height: 32)
    var hasNotch = true

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let expandedSize = CGSize(width: 460, height: 200)

    var wing: CGFloat { notchSize.height + 6 }

    /// The island's size for a state, before hover.
    func size(for state: IslandState, hovering: Bool) -> CGSize {
        switch state {
        case .idle:
            return notchSize
        case .compact:
            let grow: CGFloat = hovering ? 10 : 0
            return CGSize(width: notchSize.width + 2 * wing + grow, height: notchSize.height + (hovering ? 3 : 0))
        case .expanded:
            return CGSize(width: max(Self.expandedSize.width, notchSize.width + 2 * wing + 40),
                          height: notchSize.height + Self.expandedSize.height - 32)
        }
    }

    var currentSize: CGSize { size(for: state, hovering: hovering) }

    func expand() {
        guard state == .compact else { return }
        state = .expanded
    }

    func collapse() {
        guard state == .expanded else { return }
        state = NowPlaying.shared.hasTrack ? .compact : .idle
    }

    /// Follows the music when the player is not open.
    func syncWithMusic() {
        let playing = NowPlaying.shared.hasTrack
        switch state {
        case .idle where playing: state = .compact
        case .compact where !playing, .expanded where !playing: state = .idle
        default: break
        }
    }
}

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var music: NowPlaying = .shared
    @ObservedObject var settings: Settings = .shared

    var body: some View {
        let size = model.currentSize
        let expanded = model.state == .expanded
        let shape = IslandShape(topRadius: expanded ? 14 : 6, bottomRadius: expanded ? 34 : 12)

        ZStack(alignment: .top) {
            backgroundLayer(shape: shape, expanded: expanded)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .opacity(model.state == .idle && !model.hasNotch ? 0 : 1)
        .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 18, y: 8)
        .animation(IslandModel.spring, value: model.state)
        .animation(IslandModel.spring, value: model.hovering)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func backgroundLayer(shape: IslandShape, expanded: Bool) -> some View {
        let glass = expanded && settings.liquidGlass
        ZStack(alignment: .top) {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular.tint(.black.opacity(settings.glassTint)), in: shape)
                    .opacity(glass ? 1 : 0)
            }
            shape.fill(.black).opacity(glass ? 0 : 1)
            // The camera housing is black: keep the top band black so the
            // glass meets the hardware notch without a seam.
            LinearGradient(colors: [.black, .black, .black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: model.notchSize.height + 14)
                .clipShape(shape)
                .opacity(glass ? 1 : 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            Color.clear
        case .compact:
            CompactContent(model: model, music: music)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
        case .expanded:
            ExpandedContent(model: model, music: music)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }
}

// MARK: - Compact

private struct CompactContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var music: NowPlaying

    var body: some View {
        let height = model.currentSize.height
        HStack(spacing: 0) {
            Artwork(image: music.artwork, size: height - 10, corner: 6)
                .onTapGesture { model.expand() }
            Spacer(minLength: model.notchSize.width)
            Waveform(playing: music.isPlaying, color: music.accent, barWidth: 3, maxHeight: height * 0.42)
                .frame(width: height - 10)
        }
        .padding(.horizontal, 12)
        .frame(height: height)
    }
}

// MARK: - Expanded

private struct ExpandedContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var music: NowPlaying

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Artwork(image: music.artwork, size: 64, corner: 14)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    .onTapGesture { model.collapse() }
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(music.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Waveform(playing: music.isPlaying, color: music.accent, barWidth: 3.5, maxHeight: 22)
                    .frame(width: 30)
            }
            ProgressBar(music: music)
            Controls(music: music)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .padding(.top, model.notchSize.height + 8)
        .padding(.bottom, 16)
    }
}

// MARK: - Pieces

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Four bars moving like the iPhone's now-playing waveform.
struct Waveform: View {
    let playing: Bool
    let color: Color
    let barWidth: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth * 0.8) {
                ForEach(0..<4, id: \.self) { index in
                    let phase = Double(index) * 1.7
                    let wave = (sin(t * (5.2 + Double(index) * 0.9) + phase) + 1) / 2
                    let level = playing ? 0.25 + 0.75 * wave : 0.2
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: max(barWidth, maxHeight * level))
                }
            }
            .frame(height: maxHeight)
        }
    }
}

struct ProgressBar: View {
    @ObservedObject var music: NowPlaying
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(music.duration, 0)
            let elapsed = music.estimatedPosition(at: context.date)
            let fraction = dragFraction ?? (duration > 0 ? elapsed / duration : 0)
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(.white)
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    }
                    .frame(height: dragFraction == nil ? 5 : 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                        }
                        .onEnded { value in
                            let f = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                            music.seek(to: f * duration)
                            dragFraction = nil
                        })
                }
                .frame(height: 12)
                HStack {
                    Text(Self.format(fraction * duration))
                    Spacer()
                    Text("-" + Self.format(max(duration - fraction * duration, 0)))
                }
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
            }
            .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct Controls: View {
    @ObservedObject var music: NowPlaying
    var large = false

    var body: some View {
        HStack(spacing: large ? 46 : 40) {
            button("backward.fill", size: large ? 22 : 18) { music.previous() }
            button(music.isPlaying ? "pause.fill" : "play.fill", size: large ? 30 : 24) { music.playPause() }
            button("forward.fill", size: large ? 22 : 18) { music.next() }
        }
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
