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
    // bundle id of the owning app, or "pid:<n>" for bundle-less processes
    let id: String
    let name: String
    let icon: NSImage?
    // sorted so taps can compare process sets cheaply
    var processObjects: [AudioObjectID]
    // bundle ids of every process, or nil once any process isn't the app's own (e.g. a shared webkit service)
    var ownedBundleIDs: Set<String>? = []
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
            seenPIDs.insert(pid)
            let owner = owners[pid] ?? resolveOwner(of: pid, object: object)
            owners[pid] = owner
            let running = ((try? object.read(kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0) != 0
            let bundleID = try? object.readString(kAudioProcessPropertyBundleID)

            var app = grouped[owner.id] ?? AudioApp(id: owner.id, name: owner.name, icon: owner.icon, processObjects: [], isPlaying: false)
            app.processObjects.append(object)
            app.isPlaying = app.isPlaying || running
            if let bundleID, bundleID == owner.id || bundleID.hasPrefix(owner.id + ".") {
                app.ownedBundleIDs?.insert(bundleID)
            } else {
                app.ownedBundleIDs = nil
            }
            grouped[owner.id] = app
        }
        owners = owners.filter { seenPIDs.contains($0.key) }

        apps = grouped.values
            .map { app in
                var app = app
                app.processObjects.sort()
                return app
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onChange?()
    }

    // walks from a helper process (chrome renderer, webkit gpu process, ...) to the user-facing app
    private func resolveOwner(of pid: pid_t, object: AudioObjectID) -> Owner {
        if let app = owningApplication(of: pid) {
            return Owner(
                id: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                icon: app.icon
            )
        }
        let bundleID = (try? object.readString(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
        return Owner(id: bundleID ?? "pid:\(pid)", name: processName(pid) ?? bundleID ?? "pid \(pid)", icon: nil)
    }

    private func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        func regularApp(_ pid: pid_t) -> NSRunningApplication? {
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
            return app
        }

        // xpc services (webkit) aren't children of their app, so responsibility is checked first
        if let responsible = responsiblePID?(pid), responsible > 0, let app = regularApp(responsible) {
            return app
        }
        var current = pid
        for _ in 0 ..< 8 {
            if let app = regularApp(current) { return app }
            guard let parent = parentPID(of: current), parent > 1 else { break }
            current = parent
        }
        return nil
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

// private libsystem symbol; looked up dynamically so a missing symbol only loses xpc grouping
private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t
private let responsiblePID: ResponsiblePIDFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
}()
