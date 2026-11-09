import AppKit
import SwiftUI

/// What is playing in Music or Spotify, read with AppleScript.
///
/// Both apps post a distributed notification on every change, so updates
/// arrive at once; a slow poll keeps the position honest and notices an app
/// quitting. AppleScript never launches an app here: each script runs only
/// while its app is already running.
@MainActor
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    enum Source: String {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"
        var appName: String { self == .music ? "Music" : "Spotify" }
    }

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var source: Source?
    private var position: Double = 0
    private var positionDate = Date()
    private var trackID = ""
    private var artworkTrackID = ""

    private let queue = DispatchQueue(label: "com.parobita.island.applescript", qos: .userInitiated)
    private var timer: Timer?
    private var started = false

    var hasTrack: Bool { source != nil && !title.isEmpty }

    func estimatedPosition(at date: Date = Date()) -> Double {
        guard isPlaying else { return min(position, max(duration, 0)) }
        return min(position + date.timeIntervalSince(positionDate), max(duration, 0))
    }

    func start() {
        guard !started else { return }
        started = true
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    // MARK: Reading

    private struct Reading {
        let source: Source
        let title, artist, album: String
        let duration, position: Double
        let playing: Bool
        let id: String
        let artworkURL: String?
    }

    func refresh() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let sources = [Source.music, .spotify].filter { running.contains($0.rawValue) }
        queue.async {
            let readings = sources.compactMap { Self.read($0) }
            // A playing app wins; otherwise the first one with a track.
            let chosen = readings.first(where: \.playing) ?? readings.first
            Task { @MainActor in self.apply(chosen) }
        }
    }

    private func apply(_ reading: Reading?) {
        guard let reading else {
            if source != nil {
                source = nil
                title = ""; artist = ""; album = ""
                isPlaying = false
                artwork = nil
                trackID = ""; artworkTrackID = ""
            }
            return
        }
        if source != reading.source { source = reading.source }
        if title != reading.title { title = reading.title }
        if artist != reading.artist { artist = reading.artist }
        if album != reading.album { album = reading.album }
        if isPlaying != reading.playing { isPlaying = reading.playing }
        if abs(duration - reading.duration) > 0.5 { duration = reading.duration }
        position = reading.position
        positionDate = Date()
        let id = "\(reading.source.rawValue):\(reading.id)"
        if id != trackID {
            trackID = id
            loadArtwork(for: reading, id: id)
        }
    }

    // MARK: Artwork

    private func loadArtwork(for reading: Reading, id: String) {
        artworkTrackID = id
        queue.async {
            var image: NSImage?
            if reading.source == .music {
                image = Self.musicArtwork()
            } else if let url = reading.artworkURL.flatMap(URL.init(string:)),
                      let data = try? Data(contentsOf: url) {
                image = NSImage(data: data)
            }
            Task { @MainActor in
                guard self.artworkTrackID == id else { return }
                self.setArtwork(image)
                // The lock screen wants a big picture; streamed tracks often
                // hand over a small one or none. Ask the iTunes catalogue.
                if (image?.pixelWidth ?? 0) < 900 {
                    self.lookUpLargeArtwork(title: reading.title, artist: reading.artist, id: id)
                }
            }
        }
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        accent = image?.averageColor.map { Color(nsColor: $0.brightened()) } ?? .white
    }

    private func lookUpLargeArtwork(title: String, artist: String, id: String) {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: "\(artist) \(title)"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "5"),
        ]
        guard let url = components.url else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return }
            let wanted = artist.lowercased()
            let match = results.first { ($0["artistName"] as? String)?.lowercased().contains(wanted.prefix(12)) ?? false }
            guard let small = (match ?? results.first)?["artworkUrl100"] as? String,
                  let big = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")),
                  let imageData = try? Data(contentsOf: big),
                  let image = NSImage(data: imageData) else { return }
            Task { @MainActor in
                guard self.artworkTrackID == id else { return }
                self.setArtwork(image)
            }
        }.resume()
    }

    // MARK: Controls

    func playPause() { send("playpause"); optimisticToggle() }
    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        let value = String(format: "%.2f", max(0, seconds)).replacingOccurrences(of: ",", with: ".")
        send("set player position to \(value)")
        position = seconds
        positionDate = Date()
        objectWillChange.send()
    }

    private func optimisticToggle() {
        position = estimatedPosition()
        positionDate = Date()
        isPlaying.toggle()
    }

    private func send(_ command: String) {
        guard let source else { return }
        let script = "tell application \"\(source.appName)\" to \(command)"
        queue.async {
            _ = Self.run(script)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                self.refresh()
            }
        }
    }

    // MARK: AppleScript (on `queue` only)

    private static let separator = "‖"

    nonisolated private static func read(_ source: Source) -> Reading? {
        let script: String
        switch source {
        case .music:
            script = """
            tell application "Music"
                if player state is stopped then return "STOPPED"
                set t to current track
                return (name of t) & "\(separator)" & (artist of t) & "\(separator)" & (album of t) & "\(separator)" & (duration of t) & "\(separator)" & (player position) & "\(separator)" & (player state as string) & "\(separator)" & (persistent ID of t) & "\(separator)" & ""
            end tell
            """
        case .spotify:
            script = """
            tell application "Spotify"
                if player state is stopped then return "STOPPED"
                set t to current track
                return (name of t) & "\(separator)" & (artist of t) & "\(separator)" & (album of t) & "\(separator)" & ((duration of t) / 1000) & "\(separator)" & (player position) & "\(separator)" & (player state as string) & "\(separator)" & (id of t) & "\(separator)" & (artwork url of t)
            end tell
            """
        }
        guard let text = run(script)?.stringValue, text != "STOPPED" else { return nil }
        let parts = text.components(separatedBy: separator)
        guard parts.count >= 8, !parts[0].isEmpty else { return nil }
        return Reading(
            source: source,
            title: parts[0], artist: parts[1], album: parts[2],
            duration: number(parts[3]), position: number(parts[4]),
            playing: parts[5] == "playing",
            id: parts[6],
            artworkURL: parts[7].isEmpty ? nil : parts[7]
        )
    }

    /// AppleScript writes reals with the system's decimal separator.
    nonisolated private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    nonisolated private static func musicArtwork() -> NSImage? {
        guard let descriptor = run("tell application \"Music\" to get raw data of artwork 1 of current track") else { return nil }
        let data = descriptor.data
        return data.isEmpty ? nil : NSImage(data: data)
    }

    nonisolated private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: not allowed to control the app (Automation permission).
            if number == -1743 { NSLog("Island: Automation permission missing for \(source.prefix(40))") }
            return nil
        }
        return result
    }
}

extension NSImage {
    var pixelWidth: Int {
        representations.map(\.pixelsWide).max() ?? Int(size.width)
    }

    /// The image's average colour, from a 1×1 downsample.
    var averageColor: NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

extension NSColor {
    /// Lifted towards white so it reads on black and glass.
    func brightened() -> NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        return rgb.blended(withFraction: 0.35, of: .white) ?? rgb
    }
}
