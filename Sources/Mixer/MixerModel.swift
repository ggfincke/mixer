// Sources/Mixer/MixerModel.swift
// app state: per-app settings, persistence, launch at login & deciding which apps need a tap

import CoreAudio
import Foundation
import Observation
import ServiceManagement

struct AppSettings: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    // nil follows the system default output
    var outputUID: String?

    var gain: Float { muted ? 0 : volume }
    var isDefault: Bool { self == AppSettings() }
}

@MainActor
@Observable
final class MixerModel {
    let processes = AudioProcessMonitor()
    let outputs = OutputDevices()
    let nowPlaying = NowPlaying()
    let browserTabs = BrowserTabs()

    private(set) var settings: [String: AppSettings]
    // browser rows whose tab list is open
    private(set) var expandedBrowsers: Set<String> = []
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var permissionDenied = false
    private(set) var tapErrors: [String: String] = [:]

    @ObservationIgnored private var taps: [String: AppTap] = [:]
    @ObservationIgnored private var requestingPermission = false

    private static let settingsKey = "appSettings"

    init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode([String: AppSettings].self, from: $0) } ?? [:]
        processes.onChange = { [weak self] in self?.reconcile() }
        outputs.onChange = { [weak self] in self?.reconcile() }
        reconcile()
    }

    // playing apps (incl. the linger window), the now-playing app while paused so it can be resumed from
    // here, any app w/ non-default settings so a muted app can be unmuted after it goes quiet, & browsers
    // whose extension still lists tabs (e.g. one we muted)
    var visibleApps: [AudioApp] {
        let media = nowPlaying.info
        return processes.apps.filter {
            $0.isPlaying || media?.belongs(to: $0) == true || settings[$0.id] != nil || !tabs(for: $0).isEmpty
        }
    }

    func media(for app: AudioApp) -> NowPlayingInfo? {
        nowPlaying.info.flatMap { $0.belongs(to: app) ? $0 : nil }
    }

    func tabs(for app: AudioApp) -> [BrowserTab] {
        browserTabs.tabs(for: app.id)
    }

    func isExpanded(_ app: AudioApp) -> Bool {
        expandedBrowsers.contains(app.id)
    }

    func toggleExpanded(_ app: AudioApp) {
        if expandedBrowsers.remove(app.id) == nil {
            expandedBrowsers.insert(app.id)
        }
    }

    // the slider reads site memory rather than the tab's reported multiplier so it doesn't lag a round trip
    func tabVolume(for tab: BrowserTab) -> Float {
        browserTabs.volume(forHost: tab.host)
    }

    func setTabVolume(_ volume: Float, tab: BrowserTab, in app: AudioApp) {
        browserTabs.setVolume(volume, tab: tab, browser: app.id)
    }

    func setTabMuted(_ muted: Bool, tab: BrowserTab, in app: AudioApp) {
        browserTabs.setMuted(muted, tab: tab, browser: app.id)
    }

    func settings(for app: AudioApp) -> AppSettings {
        settings[app.id] ?? AppSettings()
    }

    func update(_ app: AudioApp, _ change: (inout AppSettings) -> Void) {
        var updated = settings(for: app)
        change(&updated)
        settings[app.id] = updated.isDefault ? nil : updated
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        reconcile()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Mixer: launch at login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // the output an app should play to: its saved device when connected, otherwise the default
    private func resolvedOutput(for settings: AppSettings) -> String? {
        if let uid = settings.outputUID, outputs.contains(uid: uid) { return uid }
        return outputs.defaultUID
    }

    // * an app only gets a tap while it differs from "100% on the default output"; untouched apps play natively
    private func reconcile() {
        var wanted: [(AudioApp, AppSettings, String)] = []
        for app in processes.apps {
            let appSettings = settings(for: app)
            guard let device = resolvedOutput(for: appSettings) else { continue }
            if appSettings.gain != 1 || device != outputs.defaultUID {
                wanted.append((app, appSettings, device))
            }
        }

        if !wanted.isEmpty, !ensurePermission() {
            wanted = []
        }

        let wantedIDs = Set(wanted.map(\.0.id))
        for (id, tap) in taps where !wantedIDs.contains(id) {
            tap.stop()
            taps[id] = nil
        }

        for (app, appSettings, device) in wanted {
            if let tap = taps[app.id], tap.target == app.tapTarget, tap.deviceUID == device {
                tap.gain.set(appSettings.gain)
                continue
            }
            // stop before restarting: two live taps on one process would both play
            taps[app.id]?.stop()
            taps[app.id] = nil
            do {
                taps[app.id] = try AppTap(target: app.tapTarget, deviceUID: device, gain: appSettings.gain)
                tapErrors[app.id] = nil
            } catch {
                tapErrors[app.id] = "\(error)"
                NSLog("Mixer: tap for \(app.id) failed: \(error)")
            }
        }
        tapErrors = tapErrors.filter { wantedIDs.contains($0.key) }
    }

    // returns true once audio capture is granted; kicks off the system prompt the first time
    private func ensurePermission() -> Bool {
        switch AudioCapturePermission.status {
        case .authorized:
            permissionDenied = false
            return true
        case .denied:
            permissionDenied = true
            return false
        case .unknown:
            guard !requestingPermission else { return false }
            requestingPermission = true
            AudioCapturePermission.request { [weak self] granted in
                guard let self else { return }
                requestingPermission = false
                permissionDenied = !granted
                reconcile()
            }
            return false
        }
    }

    func recheckPermission() {
        reconcile()
    }
}
