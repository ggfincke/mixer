// Sources/Mixer/MixerView.swift
// menu bar popover: one row per playing app plus footer controls

import AppKit
import SwiftUI

struct MixerView: View {
    let model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.visibleApps.isEmpty {
                Text("Nothing is playing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(Array(model.visibleApps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider().padding(.horizontal, 12) }
                    AppRow(model: model, app: app)
                    if model.isExpanded(app) {
                        ForEach(model.tabs(for: app)) { tab in
                            TabRow(model: model, app: app, tab: tab)
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.permissionDenied {
                HStack {
                    Text("Mixer needs System Audio Recording access to change app volumes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") { AudioCapturePermission.openSettings() }
                        .controlSize(.small)
                    Button("Retry") { model.recheckPermission() }
                        .controlSize(.small)
                }
            }
            HStack {
                // tucked in a menu so it can't be unchecked by a stray click
                Menu {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    Divider()
                    Button("Set Up Browser Extension…") { BrowserSetup.install() }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
    }
}

private struct AppRow: View {
    let model: MixerModel
    let app: AudioApp

    private var settings: AppSettings { model.settings(for: app) }

    var body: some View {
        let media = model.media(for: app)
        HStack(spacing: 10) {
            artwork(media)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(media?.title ?? app.name)
                        .font(.headline)
                        .lineLimit(1)
                    // browsers w/ the extension connected drop down into their tabs
                    if !model.tabs(for: app).isEmpty {
                        Button { model.toggleExpanded(app) } label: {
                            Image(systemName: model.isExpanded(app) ? "chevron.down" : "chevron.right")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderless)
                        .help(model.isExpanded(app) ? "Hide Tabs" : "Show Tabs")
                    }
                }
                if let media {
                    Text(media.subtitle ?? app.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Button {
                        model.update(app) { $0.muted.toggle() }
                    } label: {
                        Image(systemName: settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(settings.muted ? "Unmute" : "Mute")

                    Slider(value: volume, in: 0 ... 2)
                        .controlSize(.small)
                        .disabled(settings.muted)

                    Text("\(Int((settings.volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }

                if let error = model.tapErrors[app.id] {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .trailing, spacing: 6) {
                if let media {
                    HStack(spacing: 8) {
                        Button { model.nowPlaying.send(.togglePlayPause) } label: {
                            Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .help(media.isPlaying ? "Pause" : "Play")
                        Button { model.nowPlaying.send(.nextTrack) } label: {
                            Image(systemName: "forward.fill")
                        }
                        .help("Next")
                    }
                    .buttonStyle(.borderless)
                    .font(.title3)
                }
                deviceMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // album art w/ the app icon badged in the corner, like the system now playing menu
    @ViewBuilder
    private func artwork(_ media: NowPlayingInfo?) -> some View {
        if let image = media?.artwork {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    icon
                        .frame(width: 18, height: 18)
                        .offset(x: 4, y: 4)
                }
        } else {
            icon
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = app.icon {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(4)
        }
    }

    // snaps to 100% near the middle so "back to normal" (which drops the tap) is easy to hit
    private var volume: Binding<Double> {
        Binding(
            get: { Double(settings.volume) },
            set: { value in
                let snapped = abs(value - 1) < 0.04 ? 1 : value
                model.update(app) { $0.volume = Float(snapped) }
            }
        )
    }

    private var deviceMenu: some View {
        DeviceMenu(model: model, app: app)
    }
}

// one browser tab under its app row: favicon, title, mute & a 0-100% slider
private struct TabRow: View {
    let model: MixerModel
    let app: AudioApp
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 8) {
            favicon
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(tab.title.isEmpty ? tab.host : tab.title)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Button {
                        model.setTabMuted(!tab.isMuted, tab: tab, in: app)
                    } label: {
                        Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(tab.isMuted ? "Unmute Tab" : "Mute Tab")

                    Slider(value: volume, in: 0 ... 1)
                        .controlSize(.mini)
                        .disabled(tab.isMuted)

                    Text("\(Int((model.tabVolume(for: tab) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.leading, 62)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var favicon: some View {
        if let url = tab.favIconURL, url.scheme?.hasPrefix("http") == true || url.scheme == "data" {
            AsyncImage(url: url) { image in
                image.resizable()
            } placeholder: {
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "globe").foregroundStyle(.secondary)
        }
    }

    private var volume: Binding<Double> {
        Binding(
            get: { Double(model.tabVolume(for: tab)) },
            set: { model.setTabVolume(Float($0), tab: tab, in: app) }
        )
    }
}

// output picker for one app row
private struct DeviceMenu: View {
    let model: MixerModel
    let app: AudioApp

    private var settings: AppSettings { model.settings(for: app) }

    var body: some View {
        Menu {
            Button {
                model.update(app) { $0.outputUID = nil }
            } label: {
                checkmarkLabel("System Default", checked: settings.outputUID == nil)
            }
            Divider()
            ForEach(model.outputs.devices) { device in
                Button {
                    model.update(app) { $0.outputUID = device.uid }
                } label: {
                    checkmarkLabel(device.name, checked: settings.outputUID == device.uid)
                }
            }
        } label: {
            Image(systemName: settings.outputUID == nil ? "hifispeaker" : "hifispeaker.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(deviceHelp)
    }

    private var deviceHelp: String {
        guard let uid = settings.outputUID else { return "Output: System Default" }
        let name = model.outputs.devices.first { $0.uid == uid }?.name
        return "Output: \(name ?? "Disconnected device (using default)")"
    }

    @ViewBuilder
    private func checkmarkLabel(_ title: String, checked: Bool) -> some View {
        if checked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
