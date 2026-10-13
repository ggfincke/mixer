// Sources/Mixer/MixerApp.swift
// app entry point; lives only in the menu bar

import SwiftUI

@main
struct MixerApp: App {
    @State private var model = MixerModel()

    var body: some Scene {
        MenuBarExtra {
            MixerView(model: model)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
