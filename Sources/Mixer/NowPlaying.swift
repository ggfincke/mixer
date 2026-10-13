// Sources/Mixer/NowPlaying.swift
// streams the system now-playing item via the bundled mediaremote-adapter & sends playback commands

import AppKit
import Observation

struct NowPlayingInfo {
    let bundleID: String
    // set when a helper reports for its app (e.g. a web view inside a browser)
    let parentBundleID: String?
    let title: String
    let subtitle: String?
    let isPlaying: Bool
    let artwork: NSImage?

    func belongs(to app: AudioApp) -> Bool {
        bundleID == app.id || parentBundleID == app.id
    }
}

// ! mediaremote is private & locked to entitled processes since macOS 15.4; the adapter reaches it through
// /usr/bin/perl. if a future macOS breaks that, `info` just stays nil and the mixer keeps working
@MainActor
@Observable
final class NowPlaying {
    private(set) var info: NowPlayingInfo?

    enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var pending = Data()
    // merged stream state; the adapter sends diffs after the first full payload
    @ObservationIgnored private var payload: [String: Any] = [:]
    @ObservationIgnored private var artwork: NSImage?

    private let adapter: (script: String, framework: String)? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = resources.appendingPathComponent("MediaRemoteAdapter.framework").path
        let files = FileManager.default
        guard files.fileExists(atPath: script), files.fileExists(atPath: framework) else { return nil }
        return (script, framework)
    }()

    init() {
        start()
    }

    func send(_ command: Command) {
        guard let adapter else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [adapter.script, adapter.framework, "send", String(command.rawValue)]
        try? process.run()
    }

    private func start() {
        guard let adapter else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [adapter.script, adapter.framework, "stream", "--debounce=100"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        // main queue (not a Task) keeps chunks in order
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self?.restart() } }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("Mixer: now playing adapter failed to launch: \(error)")
        }
    }

    private func restart() {
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        process = nil
        pending.removeAll()
        payload.removeAll()
        artwork = nil
        info = nil
        start()
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex ..< newline]
            pending.removeSubrange(pending.startIndex ... newline)
            apply(line)
        }
    }

    private func apply(_ line: Data) {
        guard
            let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let update = message["payload"] as? [String: Any]
        else { return }

        if (message["diff"] as? Bool) != true {
            payload = [:]
            artwork = nil
        }
        for (key, value) in update {
            payload[key] = value is NSNull ? nil : value
        }
        if update.keys.contains("artworkData") {
            artwork = (payload["artworkData"] as? String)
                .flatMap { Data(base64Encoded: $0) }
                .flatMap(NSImage.init(data:))
        }

        guard let bundleID = payload["bundleIdentifier"] as? String, let title = payload["title"] as? String else {
            info = nil
            return
        }
        let subtitle = [payload["artist"], payload["album"]]
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty }
            .joined(separator: " – ")
        info = NowPlayingInfo(
            bundleID: bundleID,
            parentBundleID: payload["parentApplicationBundleIdentifier"] as? String,
            title: title,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            isPlaying: payload["playing"] as? Bool ?? false,
            artwork: artwork
        )
    }
}
