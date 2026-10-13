// Sources/Mixer/AudioCapturePermission.swift
// checks & requests the "system audio recording" grant before any tap is created

import AppKit

// ! a denied tap still mutes the app but delivers silence, so taps must wait for a real grant.
// there's no public preflight api for this service; the tcc spi is the same one screen recorders use
enum AudioCapturePermission {
    enum Status {
        case authorized
        case denied
        case unknown
    }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture"
    private nonisolated(unsafe) static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: PreflightFunction.self)(service as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    @MainActor
    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else {
            completion(false)
            return
        }
        unsafeBitCast(symbol, to: RequestFunction.self)(service as CFString, nil) { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
