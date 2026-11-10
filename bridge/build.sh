#!/bin/zsh
#
#  build.sh
#  PrimoKKMK1Bridge
#
#  Created by George Senger on 11/9/2026.
#  Copyright © 2026 Primo Studios. All rights reserved.
#
#  Licensed under the MIT License. See LICENSE in the project root or
#  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
#
#  Builds the bridge on its own, build/PrimoKKMK1Bridge, with a fresh version stamp (tools/stamp_version.sh).
#  It's built to a temporary file and moved into place, so a bridge running from build/ isn't disturbed.

set -euo pipefail
cd "${0:A:h}/.."

version=$(tools/stamp_version.sh)
swiftc -O bridge/Sources/*.swift build/Version.swift -o build/PrimoKKMK1Bridge.tmp
mv build/PrimoKKMK1Bridge.tmp build/PrimoKKMK1Bridge
echo "built build/PrimoKKMK1Bridge $version"
