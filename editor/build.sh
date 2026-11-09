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
#  inside the app (Contents/MacOS), for the editor's bridge switch; and makes the app icon from
#  editor/img/appicon.png.

set -euo pipefail
cd "${0:A:h}/.."

app=build/PrimoKKMK1Editor.app
mkdir -p $app/Contents/MacOS $app/Contents/Resources

# Each program is built to a temporary file, signed, then moved into place: a bridge started from the app
# keeps running from the old file untouched while it's replaced.
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    editor/Sources/*.swift \
    bridge/Sources/Hardware.swift bridge/Sources/Config.swift bridge/Sources/ReaperModel.swift \
    -o build/PrimoKKMK1Editor.tmp
swiftc -O bridge/Sources/*.swift -o build/PrimoKKMK1Bridge.tmp
codesign --force --sign - build/PrimoKKMK1Bridge.tmp 2>/dev/null
mv build/PrimoKKMK1Editor.tmp $app/Contents/MacOS/PrimoKKMK1Editor
mv build/PrimoKKMK1Bridge.tmp $app/Contents/MacOS/PrimoKKMK1Bridge
cp editor/Info.plist $app/Contents/Info.plist

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
echo "built $app"
