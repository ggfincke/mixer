// Sources/Mixer/OutputDevices.swift
// tracks the output-capable audio devices & the system default output

import CoreAudio
import Observation

struct OutputDevice: Identifiable, Hashable {
    let uid: String
    let name: String

    var id: String { uid }
}

@MainActor
@Observable
final class OutputDevices {
    // prefix for the private aggregate devices AppTap creates, so they never show up as choices
    nonisolated static let aggregateUIDPrefix = "com.ggfincke.mixer.tap."

    private(set) var devices: [OutputDevice] = []
    private(set) var defaultUID: String?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var listeners: [PropertyListener] = []

    init() {
        refresh()
        listeners = [
            PropertyListener(.system, kAudioHardwarePropertyDevices) { [weak self] in self?.refresh() },
            PropertyListener(.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.refresh() },
        ]
    }

    func contains(uid: String) -> Bool {
        devices.contains { $0.uid == uid }
    }

    private func refresh() {
        let ids = (try? AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyDevices)) ?? []
        let found = ids.compactMap { id -> OutputDevice? in
            guard
                let streams = try? id.readObjectIDs(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
                !streams.isEmpty,
                let uid = try? id.readString(kAudioDevicePropertyDeviceUID),
                !uid.hasPrefix(Self.aggregateUIDPrefix),
                let name = try? id.readString(kAudioObjectPropertyName)
            else { return nil }
            return OutputDevice(uid: uid, name: name)
        }
        let defaultID = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
        let newDefault = defaultID.flatMap { try? $0.readString(kAudioDevicePropertyDeviceUID) }

        // device list notifications also fire when our own aggregates come & go; ignore those
        guard found != devices || newDefault != defaultUID else { return }
        devices = found
        defaultUID = newDefault
        onChange?()
    }
}
