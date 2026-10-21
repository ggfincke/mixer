# Mixer

A small macOS menu bar app for controlling volume per app.

macOS gives you one volume slider for everything. When a YouTube video is drowning out your music, or an app keeps playing notification sounds during a call, the only fix is to dig into that app's own settings, if it even has one. Mixer adds what's missing: a slider for each app that's playing sound, right in the menu bar.

It also replaces Apple's Now Playing menu bar item. The app that's playing media shows its artwork and title, with play/pause and skip buttons next to its slider.

## What it's good for

- **Balancing apps against each other.** Keep music quiet under a video, or turn a loud game down without touching anything else.
- **Silencing noisy apps.** Mute an app's sound effects completely, including Electron and Chromium apps like Slack, Discord, or Claude that play sounds from helper processes.
- **Boosting quiet sources.** Go up to 200% for a quiet video or call. A soft limiter keeps it from clipping harshly.
- **Sending apps to different outputs.** Play music on the speakers and a call in your headphones. If a chosen device disconnects, the app falls back to the default output, then switches back when the device returns.
- **Remembering settings.** Volumes are saved per app and applied again the next time that app makes sound. An app you've changed stays in the list while it's running, so a muted app can be unmuted after it goes quiet.

Apps you leave at 100% on the default output aren't touched at all. Mixer only reroutes an app's audio once you change something about it.

## Requirements

- macOS 15 or later. macOS 26 or later is recommended: Mixer then taps apps by bundle ID, which also catches helper processes that start mid-sound.
- Xcode or the Swift 6 toolchain, plus `cmake`, to build.

## Build and install

```sh
git clone --recursive https://github.com/ggfincke/mixer.git
cd mixer
scripts/build-app.sh --install
```

This builds `Mixer.app`, copies it to `~/Applications`, and launches it. The first time you change an app's volume, macOS asks for **System Audio Recording** permission, which Mixer needs to reroute app audio. Launch at login is in the gear menu.

To hide Apple's Now Playing item, go to System Settings → Menu Bar → Now Playing → Don't Show.

## How it works

- **Volume:** Core Audio process taps (macOS 14.2+). Mixer taps an app with its own output muted, then plays the audio back at your chosen volume on your chosen device.
- **Now Playing:** [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause), vendored as a submodule. It reads macOS's private MediaRemote framework, which Apple restricted in macOS 15.4.

## Limitations

- Only one app at a time gets the now-playing card, because MediaRemote only reports the app macOS currently considers "now playing." Every app still gets its own slider.
- The now-playing feature depends on a private framework, so a future macOS update could break it. If that happens, the volume controls keep working.
- While Mixer is rerouting any app's audio, macOS may show its purple system-audio recording indicator.
- System alert sounds are hidden rather than listed; use the alert volume slider in System Settings → Sound for those.
- Without the browser extension below, a browser is one row: every tab mixes inside one browser audio process before macOS sees it.

## Browser tabs

Chromium browsers (Chrome, Brave, Edge, Arc, Vivaldi) can expand into their audible tabs with a mute button and a 0–100% slider per tab. This needs a small companion extension, loaded unpacked:

1. In Mixer's gear menu choose **Set Up Browser Extension…**. Mixer writes a native-messaging manifest for each installed Chromium browser and reveals the extension folder in Finder.
2. In the browser open `chrome://extensions`, turn on Developer mode, click **Load unpacked**, and pick that folder. Repeat the setup step after reinstalling Mixer.

Tab mute uses the browser's own mute. Tab volume scales the page's audio and video elements, so it works on YouTube and most media sites but not on pages that use Web Audio directly (games, some players); those still mute. Tab volume is remembered per site; tab mute is not. Tabs can't be boosted above 100%.

## License

MIT
