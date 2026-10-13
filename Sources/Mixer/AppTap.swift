// Sources/Mixer/AppTap.swift
// one process tap + private aggregate device that replays an app's audio at our gain on a chosen output

import CoreAudio
import Foundation
import Synchronization

// Gain shared between the main thread (writer) and the realtime io thread (reader).
final class GainControl: @unchecked Sendable {
    private let target: Atomic<UInt32>
    // only touched on the io thread
    private var current: Float

    init(_ initial: Float) {
        target = Atomic(initial.bitPattern)
        current = initial
    }

    func set(_ gain: Float) {
        target.store(gain.bitPattern, ordering: .relaxed)
    }

    // returns the ramp for the next buffer so gain changes don't click
    fileprivate func nextRamp() -> (start: Float, end: Float) {
        let end = Float(bitPattern: target.load(ordering: .relaxed))
        defer { current = end }
        return (current, end)
    }
}

@MainActor
final class AppTap {
    let target: TapTarget
    let deviceUID: String
    let gain: GainControl

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(target: TapTarget, deviceUID: String, gain initialGain: Float) throws {
        self.target = target
        self.deviceUID = deviceUID
        gain = GainControl(initialGain)
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    private func start() throws {
        // * mutedWhenTapped silences the app's own output only while we read the tap, so a crash restores it
        let description: CATapDescription
        switch target {
        case let .processes(objects):
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        case let .bundleIDs(bundleIDs):
            description = CATapDescription(stereoMixdownOfProcesses: [])
            if #available(macOS 26, *) {
                description.bundleIDs = bundleIDs
            }
        }
        if #available(macOS 26, *) {
            description.isProcessRestoreEnabled = true
        }
        description.name = "Mixer"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixer",
            kAudioAggregateDeviceUIDKey: OutputDevices.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        // the aggregate's input buffers start w/ the output device's own inputs (e.g. a headset mic) and
        // end w/ the tap; skip the device inputs & tell the hal we don't use them so no mic gets opened
        let skip = try deviceID(forUID: deviceUID)
            .readObjectIDs(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            .count

        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, ioBlock(skipInputs: skip, gain: gain)),
            "create io proc"
        )
        if skip > 0, let procID {
            disableInputStreams(count: skip, procID: procID)
        }
        try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // turns off the leading `count` input streams for our io proc; anything after (the tap) stays on
    private func disableInputStreams(count: Int, procID: AudioDeviceIOProcID) {
        guard
            let total = try? aggregateID.readObjectIDs(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count,
            total > 0
        else { return }
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let byteCount = flagsOffset + total * MemoryLayout<UInt32>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }

        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(total)
        let flags = (raw + flagsOffset).bindMemory(to: UInt32.self, capacity: total)
        for index in 0 ..< total {
            flags[index] = index < count ? 0 : 1
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(byteCount), raw)
    }
}

private func deviceID(forUID uid: String) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var qualifier = uid as CFString
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(
        withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        },
        "find device \(uid)"
    )
    guard device != kAudioObjectUnknown else {
        throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "find device \(uid)")
    }
    return device
}

// * built outside the main actor: a closure formed inside AppTap would inherit @MainActor isolation and
// trap on swift's runtime isolation check when the hal calls it from its io thread
private func ioBlock(skipInputs: Int, gain: GainControl) -> AudioDeviceIOBlock {
    { _, input, _, output, _ in
        render(input: input, output: output, skipInputs: skipInputs, gain: gain)
    }
}

// runs on the realtime io thread: no allocation, locks or main-actor access
private func render(
    input: UnsafePointer<AudioBufferList>,
    output: UnsafeMutablePointer<AudioBufferList>,
    skipInputs: Int,
    gain: GainControl
) {
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outputs = UnsafeMutableAudioBufferListPointer(output)
    let ramp = gain.nextRamp()

    // locate the tap's left & right channels, whether interleaved or one buffer per channel
    var left: UnsafeMutablePointer<Float>?
    var right: UnsafeMutablePointer<Float>?
    var leftStride = 1
    var rightStride = 1
    var frames = Int.max
    var found = 0
    var index = skipInputs
    while index < inputs.count, found < 2 {
        let buffer = inputs[index]
        index += 1
        let channels = Int(buffer.mNumberChannels)
        guard let data = buffer.mData, channels > 0 else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        for channel in 0 ..< min(channels, 2 - found) {
            if found == 0 {
                left = samples + channel
                leftStride = channels
            } else {
                right = samples + channel
                rightStride = channels
            }
            found += 1
        }
    }
    if right == nil {
        right = left
        rightStride = leftStride
    }

    var totalOutputChannels = 0
    for buffer in outputs {
        totalOutputChannels += Int(buffer.mNumberChannels)
    }

    var outputChannel = 0
    for buffer in outputs {
        let channels = Int(buffer.mNumberChannels)
        guard let data = buffer.mData, channels > 0 else { continue }
        memset(data, 0, Int(buffer.mDataByteSize))
        defer { outputChannel += channels }
        guard let left, let right, frames != Int.max else { continue }

        let samples = data.assumingMemoryBound(to: Float.self)
        let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        let boosting = max(ramp.start, ramp.end) > 1
        let step = count > 0 ? (ramp.end - ramp.start) / Float(count) : 0

        // stereo source -> first two device channels; a mono device gets the mixdown; extra channels stay silent
        for channel in 0 ..< channels {
            let target = outputChannel + channel
            guard target < 2 else { break }
            var level = ramp.start
            for frame in 0 ..< count {
                let sample: Float = if totalOutputChannels == 1 {
                    (left[frame * leftStride] + right[frame * rightStride]) * 0.5
                } else if target == 0 {
                    left[frame * leftStride]
                } else {
                    right[frame * rightStride]
                }
                let scaled = sample * level
                samples[frame * channels + channel] = boosting ? softLimit(scaled) : scaled
                level += step
            }
        }
    }
}

// transparent below the knee, then eases peaks toward full scale instead of hard clipping
@inline(__always)
private func softLimit(_ sample: Float) -> Float {
    let knee: Float = 0.8
    let magnitude = abs(sample)
    guard magnitude > knee else { return sample }
    let limited = knee + (1 - knee) * tanh((magnitude - knee) / (1 - knee))
    return sample < 0 ? -limited : limited
}
