// Sources/Mixer/AudioProcessMonitor.swift
// lists processes known to the audio server & groups helpers under the app that owns them

import AppKit
import CoreAudio
import Darwin
import Observation

// What a tap captures for one app.
enum TapTarget: Equatable {
    // matched by the hal, including processes that start after the tap (macOS 26+)
    case bundleIDs([String])
    case processes([AudioObjectID])
}

struct AudioApp: Identifiable {
    // bundle id of the owning app, "exe:<path>" for bundle-less processes, or "pid:<n>" as a last resort
    let id: String
    let name: String
    let icon: NSImage?
    // sorted so taps can compare process sets cheaply
    var processObjects: [AudioObjectID]
    // bundle ids of every process, or nil once any process isn't the app's own (e.g. a shared webkit service)
    var ownedBundleIDs: Set<String>? = []
    // output running now, or stopped within the linger window so short sounds don't flicker the row
    var isPlaying: Bool

    // * chromium-style apps spawn a fresh helper per sound; a process-list tap misses its first moments, so
    // tap by bundle id whenever every process belongs to this app
    var tapTarget: TapTarget {
        if #available(macOS 26, *), let ownedBundleIDs, !ownedBundleIDs.isEmpty {
            return .bundleIDs(ownedBundleIDs.sorted())
        }
        return .processes(processObjects)
    }
}

@MainActor
@Observable
final class AudioProcessMonitor {
    // every app w/ at least one audio process object, playing or not
    private(set) var apps: [AudioApp] = []

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var listListener: PropertyListener?
    @ObservationIgnored private var runningListeners: [AudioObjectID: PropertyListener] = [:]
    @ObservationIgnored private var owners: [pid_t: Owner] = [:]
    // last time each app had output running; drives the linger window
    @ObservationIgnored private var lastHeard: [String: Date] = [:]
    @ObservationIgnored private var lingerTimer: Task<Void, Never>?

    private static let linger: TimeInterval = 5

    // system alert sounds: a ~200ms blip per beep, and macOS has its own alert-volume slider
    private static let hiddenBundleIDs: Set<String> = ["systemsoundserverd"]

    // daemons that play audio on behalf of a feature rather than an app
    private static let systemProcesses: [String: (name: String, symbol: String)] = [
        "com.apple.CoreSpeech": ("Speech", "waveform"),
        "com.apple.avconferenced": ("FaceTime", "video"),
        "com.apple.TelephonyUtilities": ("Phone", "phone"),
        "com.apple.accessibility.heard": ("VoiceOver", "accessibility"),
    ]

    private struct Owner {
        let id: String
        let name: String
        let icon: NSImage?
    }

    init() {
        listListener = PropertyListener(.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        let objects = (try? AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyProcessObjectList)) ?? []
        let live = Set(objects)
        let now = Date()

        for object in objects where runningListeners[object] == nil {
            runningListeners[object] = PropertyListener(object, kAudioProcessPropertyIsRunningOutput) { [weak self] in
                self?.refresh()
            }
        }
        for object in runningListeners.keys where !live.contains(object) {
            runningListeners[object] = nil
        }

        var grouped: [String: AudioApp] = [:]
        var seenPIDs = Set<pid_t>()
        for object in objects {
            guard let pid = try? object.read(kAudioProcessPropertyPID, as: pid_t.self), pid > 0, pid != getpid() else { continue }
            let bundleID = (try? object.readString(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
            if let bundleID, Self.hiddenBundleIDs.contains(bundleID) { continue }
            seenPIDs.insert(pid)
            let owner = owners[pid] ?? resolveOwner(of: pid, bundleID: bundleID)
            owners[pid] = owner
            let running = ((try? object.read(kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0) != 0

            var app = grouped[owner.id] ?? AudioApp(id: owner.id, name: owner.name, icon: owner.icon, processObjects: [], isPlaying: false)
            app.processObjects.append(object)
            app.isPlaying = app.isPlaying || running
            // an electron app shipping the stock com.github.Electron.helper id lands here on purpose: that id
            // is shared across apps, so tapping it would capture all of them
            if let bundleID, bundleID == owner.id || bundleID.hasPrefix(owner.id + ".") {
                app.ownedBundleIDs?.insert(bundleID)
            } else {
                app.ownedBundleIDs = nil
            }
            grouped[owner.id] = app
        }
        owners = owners.filter { seenPIDs.contains($0.key) }

        var nextExpiry: Date?
        for (id, app) in grouped {
            if app.isPlaying {
                lastHeard[id] = now
            } else if let heard = lastHeard[id] {
                let expiry = heard.addingTimeInterval(Self.linger)
                if expiry > now {
                    grouped[id]?.isPlaying = true
                    nextExpiry = min(nextExpiry ?? expiry, expiry)
                }
            }
        }
        lastHeard = lastHeard.filter { grouped[$0.key] != nil }
        scheduleRefresh(at: nextExpiry)

        apps = grouped.values
            .map { app in
                var app = app
                app.processObjects.sort()
                return app
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onChange?()
    }

    // one pending refresh for the earliest linger expiry, so rows drop on time w/o polling
    private func scheduleRefresh(at date: Date?) {
        lingerTimer?.cancel()
        lingerTimer = nil
        guard let date else { return }
        lingerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(date.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // walks from a helper process (chrome renderer, webkit gpu process, ...) to the user-facing app
    private func resolveOwner(of pid: pid_t, bundleID: String?) -> Owner {
        if let app = owningApplication(of: pid) {
            return Owner(
                id: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                icon: app.icon
            )
        }
        if let bundleID {
            if let system = Self.systemProcesses[bundleID] {
                return Owner(id: bundleID, name: system.name, icon: NSImage(systemSymbolName: system.symbol, accessibilityDescription: system.name))
            }
            return Owner(id: bundleID, name: processName(pid) ?? bundleID, icon: nil)
        }
        // no bundle at all (wine, java, afplay): group every process of the same binary
        if let path = executablePath(pid) {
            return Owner(id: "exe:\(path)", name: (path as NSString).lastPathComponent, icon: nil)
        }
        return Owner(id: "pid:\(pid)", name: processName(pid) ?? "pid \(pid)", icon: nil)
    }

    private func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        // the process itself first: an app launched from a shell is "responsible for" by the terminal
        if let app = topLevelApp(pid) { return app }
        // xpc services (webkit) aren't children of their app, so responsibility is checked before parents
        if let responsible = responsiblePID?(pid), responsible > 0, responsible != pid, let app = topLevelApp(responsible) {
            return app
        }
        var current = pid
        for _ in 0 ..< 8 {
            guard let parent = parentPID(of: current), parent > 1 else { break }
            if let app = topLevelApp(parent) { return app }
            current = parent
        }
        return nil
    }

    // a user-facing app: regular apps always; accessory (menu bar) apps only as a standalone .app, which
    // rules out xpc services like com.apple.WebKit.GPU that register as accessory, & nested helper apps
    private func topLevelApp(_ pid: pid_t) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        switch app.activationPolicy {
        case .regular:
            return app
        case .accessory:
            guard let url = app.bundleURL, url.pathExtension == "app" else { return nil }
            let ancestors = url.deletingLastPathComponent().pathComponents
            return ancestors.contains { $0.hasSuffix(".app") } ? nil : app
        default:
            return nil
        }
    }
}

private func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

private func processName(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 256)
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}

private func executablePath(_ pid: pid_t) -> String? {
    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) isn't imported into swift
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}

// private libsystem symbol; looked up dynamically so a missing symbol only loses xpc grouping
private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t
private let responsiblePID: ResponsiblePIDFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
}()
