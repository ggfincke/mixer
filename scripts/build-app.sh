#!/usr/bin/env bash
# scripts/build-app.sh
# builds Mixer.app from the swift package; --install copies it to ~/Applications & relaunches it

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Mixer.app"
cd "$root"

swift build -c release
bin="$(swift build -c release --show-bin-path)"

# now-playing info comes from the vendored mediaremote-adapter (git submodule), built out of tree
adapter_src="$root/Vendor/mediaremote-adapter"
adapter_build="$root/build/adapter"
if [[ ! -f "$adapter_src/CMakeLists.txt" ]]; then
    git -C "$root" submodule update --init Vendor/mediaremote-adapter
fi
cmake -S "$adapter_src" -B "$adapter_build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$adapter_build" --target MediaRemoteAdapter >/dev/null

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Mixer" "$app/Contents/MacOS/Mixer"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R "$adapter_build/MediaRemoteAdapter.framework" "$app/Contents/Resources/"
cp "$adapter_src/bin/mediaremote-adapter.pl" "$app/Contents/Resources/"

# a stable identity keeps the audio-capture grant across rebuilds; ad-hoc signing re-prompts every build
identity="${MIXER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${identity:--}" "$app/Contents/Resources/MediaRemoteAdapter.framework"
codesign --force --sign "${identity:--}" "$app"
echo "built $app (signed: ${identity:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Mixer || true
    # launching before the old instance exits fails w/ LaunchServices error -600
    while pgrep -xq Mixer; do sleep 0.2; done
    rm -rf "$HOME/Applications/Mixer.app"
    mkdir -p "$HOME/Applications"
    cp -R "$app" "$HOME/Applications/Mixer.app"
    open "$HOME/Applications/Mixer.app"
    echo "installed & launched ~/Applications/Mixer.app"
fi
