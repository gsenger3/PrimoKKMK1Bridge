//
//  Hardware.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The Komplete Kontrol S-series MK1's USB HID map: models, report IDs, button bits and light slots.

import Foundation

// MARK: - Hardware map (verified on an S61 MK1, firmware 72)

let niVendorID = 0x17cc
let mk1Models: [Int: String] = [0x1340: "S25 MK1", 0x1350: "S49 MK1", 0x1360: "S61 MK1", 0x1410: "S88 MK1"]
let reportUI: UInt8 = 0x01    // input: buttons, touch, Navigate knob, knob positions, base note
let reportPage: UInt8 = 0x0f  // input: knob page; only sent while the keyboard is in MIDI mode
let reportLights: UInt8 = 0x80  // output: 25 button-light brightness bytes
let reportInit: UInt8 = 0xa0  // output: switch to native mode
let reportDisplay: UInt8 = 0xe0  // output: one display row (value bars and dots, or text)
let reportLightGuide: UInt8 = 0x82  // output: the light guide, red, green, blue (0-127) per key, lowest key first
/// Keys per model: the light guide report has 3 bytes per key (183 on the S61, checked on the keyboard 2026-11-11).
let mk1KeyCount: [Int: Int] = [0x1340: 25, 0x1350: 49, 0x1360: 61, 0x1410: 88]
/// At equal values the light guide looks purple-white; this balance looked neutral on an S61 MK1 (2026-11-11).
let lightGuideWhiteBalance = (red: 0.75, green: 1.0, blue: 0.67)
let lightCount = 25

struct ButtonDef { let name: String; let bit: Int; let cc: Int }

/// Button bit n is in report byte 1 + n/8, mask 1 << (n % 8). Default CCs avoid the defined CCs.
let buttonDefs: [ButtonDef] = [
    ButtonDef(name: "NavigateClick", bit: 0, cc: 90),
    ButtonDef(name: "PresetUp", bit: 1, cc: 119),
    ButtonDef(name: "Enter", bit: 2, cc: 118),
    ButtonDef(name: "PresetDown", bit: 3, cc: 85),
    ButtonDef(name: "Browse", bit: 4, cc: 115),
    ButtonDef(name: "Instance", bit: 5, cc: 116),
    ButtonDef(name: "OctaveDown", bit: 6, cc: 111),
    ButtonDef(name: "OctaveUp", bit: 7, cc: 112),
    ButtonDef(name: "Stop", bit: 8, cc: 103),
    ButtonDef(name: "Rec", bit: 9, cc: 104),
    ButtonDef(name: "Play", bit: 10, cc: 102),
    ButtonDef(name: "NavRight", bit: 11, cc: 89),
    ButtonDef(name: "NavDown", bit: 12, cc: 87),
    ButtonDef(name: "NavLeft", bit: 13, cc: 88),
    ButtonDef(name: "Back", bit: 14, cc: 117),
    ButtonDef(name: "NavUp", bit: 15, cc: 86),
    ButtonDef(name: "Shift", bit: 16, cc: 108),
    ButtonDef(name: "Scale", bit: 17, cc: 109),
    ButtonDef(name: "Arp", bit: 18, cc: 110),
    ButtonDef(name: "Loop", bit: 19, cc: 105),
    ButtonDef(name: "PageRight", bit: 20, cc: 114),
    ButtonDef(name: "PageLeft", bit: 21, cc: 113),
    ButtonDef(name: "Rewind", bit: 22, cc: 106),
    ButtonDef(name: "FastForward", bit: 23, cc: 107),
]
let shiftBit = 16
let knobTouchFirstBit = 24  // knobs 1-8 touch = bits 24-31
let navigateTouchBit = 32

/// Light positions in output report 0x80, from DrivenByMoss. Octave −/+ and the Navigate click have none.
let lightSlot: [String: Int] = [
    "Shift": 0, "Scale": 1, "Arp": 2, "Loop": 3, "Rewind": 4, "FastForward": 5, "Play": 6, "Rec": 7,
    "Stop": 8, "PageLeft": 9, "PageRight": 10, "Browse": 11, "PresetUp": 12, "Instance": 13,
    "PresetDown": 14, "Back": 15, "NavUp": 16, "Enter": 17, "NavLeft": 18, "NavDown": 19, "NavRight": 20,
]

func isSet(_ r: [UInt8], _ bit: Int) -> Bool { r[1 + bit / 8] & UInt8(1 << (bit % 8)) != 0 }

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(("PrimoKKMK1Bridge: " + s + "\n").data(using: .utf8)!)
    exit(2)
}
