#!/bin/zsh
#
#  build.sh
#  PrimoKKMK1Bridge
#
#  Created by George Senger on 11/8/2026.
#  Copyright © 2026 Primo Studios. All rights reserved.
#
#  Licensed under the MIT License. See LICENSE in the project root or
#  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
#
#  Builds the editor app, build/PrimoKKMK1Editor.app. It compiles the bridge's own config, hardware and REAPER
#  model files, so the editor reads, checks and writes exactly what the bridge does; puts a copy of the bridge
#  inside the app (Contents/MacOS), for the editor's bridge switch; stamps both with one version, 1.0 (Build ID),
#  from tools/stamp_version.sh, which the About box shows; and makes the app icon from editor/img/appicon.png.
#
#    editor/build.sh [--arch arm64|x86_64|universal] [--keep-version]
#
#  --arch: what the app runs on. The default is this Mac's own (arm64 on Apple Silicon); universal runs on Apple
#  Silicon and Intel Macs, at about twice the size. Both programs need macOS 14 or later, whatever the architecture.
#  --keep-version: use the version build/version.env already has instead of stamping a new one, so several builds
#  share one (tools/make_release.sh).

set -euo pipefail
cd "${0:A:h}/.."

arch=$(uname -m)
keep_version=false
while (( $# )); do
    case $1 in
        --arch) arch=${2:-}; shift 2 ;;
        --keep-version) keep_version=true; shift ;;
        *) echo "usage: editor/build.sh [--arch arm64|x86_64|universal] [--keep-version]" >&2; exit 2 ;;
    esac
done
case $arch in
    arm64|x86_64) archs=($arch) ;;
    universal) archs=(arm64 x86_64) ;;
    *) echo "editor/build.sh: --arch must be arm64, x86_64 or universal, not \"$arch\"" >&2; exit 2 ;;
esac
min_macos=14.0

app=build/PrimoKKMK1Editor.app
mkdir -p $app/Contents/MacOS $app/Contents/Resources

# One version stamp for the editor and its bridge: build/Version.swift and build/version.env.
if $keep_version && [[ -f build/version.env && -f build/Version.swift ]]; then
    source build/version.env
    version="$APP_VERSION ($APP_BUILD_ID)"
else
    version=$(tools/stamp_version.sh)
    source build/version.env
fi

# Compile a program for each architecture, for macOS 14 or later, and join them into one file with lipo when
# there's more than one. Usage: compile OUTPUT SWIFTC-ARGUMENTS...
compile() {
    local out=$1; shift
    local slices=()
    for a in $archs; do
        swiftc -O -target $a-apple-macos$min_macos "$@" -o $out.$a
        slices+=($out.$a)
    done
    if (( ${#slices} > 1 )); then lipo -create $slices -output $out; rm -f $slices; else mv $slices[1] $out; fi
}

# Each program is built to a temporary file, signed, then moved into place: a bridge started from the app
# keeps running from the old file untouched while it's replaced.
compile build/PrimoKKMK1Editor.tmp -swift-version 5 -parse-as-library \
    editor/Sources/*.swift \
    bridge/Sources/Hardware.swift bridge/Sources/Config.swift bridge/Sources/ReaperModel.swift build/Version.swift
compile build/PrimoKKMK1Bridge.tmp bridge/Sources/*.swift build/Version.swift
codesign --force --sign - build/PrimoKKMK1Bridge.tmp 2>/dev/null
mv build/PrimoKKMK1Editor.tmp $app/Contents/MacOS/PrimoKKMK1Editor
mv build/PrimoKKMK1Bridge.tmp $app/Contents/MacOS/PrimoKKMK1Bridge
cp editor/Info.plist $app/Contents/Info.plist
cp reaper/PrimoKKMK1Bridge_TrackColor.lua $app/Contents/Resources/  # for REAPER (Bridge ▸ Show REAPER Track Colour Script)
# The About box shows "Version <CFBundleShortVersionString> (<CFBundleVersion>)": 1.0 (Build ID).
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" $app/Contents/Info.plist
plutil -replace CFBundleVersion -string "$APP_BUILD_ID" $app/Contents/Info.plist

# App icon: every size macOS asks for, scaled from the one PNG, packed into AppIcon.icns.
iconset=build/AppIcon.iconset
rm -rf $iconset
mkdir -p $iconset
for size in 16 32 128 256 512; do
    sips -z $size $size editor/img/appicon.png --out $iconset/icon_${size}x${size}.png >/dev/null
    sips -z $((size * 2)) $((size * 2)) editor/img/appicon.png --out $iconset/icon_${size}x${size}@2x.png >/dev/null
done
iconutil -c icns $iconset -o $app/Contents/Resources/AppIcon.icns
rm -rf $iconset
touch $app  # so Finder and the Dock pick up a changed icon

codesign --force --sign - $app 2>/dev/null
echo "built $app $version, $arch"
