#!/bin/zsh
#
#  render_guide_images.sh
#  PrimoKKMK1Bridge
#
#  Created by George Senger on 11/11/2026.
#  Copyright © 2026 Primo Studios. All rights reserved.
#
#  Licensed under the MIT License. See LICENSE in the project root or
#  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
#
#  Redraws the keyboard pictures in doc/img/ for the user guide (doc/GUIDE.md) from the editor's panel drawing and
#  the current defaults. Run it after changing a default or the drawing.

set -euo pipefail
cd "${0:A:h}/.."

mkdir -p build doc/img
swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    tools/render_guide_images.swift \
    editor/Sources/Catalog.swift editor/Sources/EditorModel.swift editor/Sources/PanelView.swift \
    editor/Sources/BridgeControl.swift \
    bridge/Sources/Hardware.swift bridge/Sources/Config.swift bridge/Sources/ReaperModel.swift \
    -o build/render_guide_images
build/render_guide_images doc/img
