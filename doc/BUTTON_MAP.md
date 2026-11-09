# KKS61 MK1 control map

Captured 2026-11-07 17:47 with `tools/kkmap` from `KKS61 Button Map.md`. Firmware 72, stock MIDI mode, no NI software running.

| # | Section | Control | Reports as |
|---|---|---|---|
| 1 | Transpose | Oct - | HID button bit 6 (byte 1, mask 0x40) |
| 2 | Transpose | Oct + | HID button bit 7 (byte 1, mask 0x80)<br>base note 24 → 36 |
| 3 | Transpose | Pitch Strip | MIDI pitch bend ch1 (Port 1) [112..16383] |
| 4 | Transpose | Mod Strip | MIDI CC1 ch1 (Port 1) [0..113] |
| 5 | Perform | Shift | HID button bit 16 (byte 3, mask 0x01) |
| 6 | Perform | Scale (Edit) | nothing (no HID, no MIDI) |
| 7 | Perform | Arp (Edit) | nothing (no HID, no MIDI) |
| 8 | Transport | Loop | HID button bit 19 (byte 3, mask 0x08) |
| 9 | Transport | RWD | HID button bit 22 (byte 3, mask 0x40) |
| 10 | Transport | FFW | HID button bit 23 (byte 3, mask 0x80) |
| 11 | Transport | Play (Restart) | HID button bit 10 (byte 2, mask 0x04) |
| 12 | Transport | REC (Count In) | HID button bit 9 (byte 2, mask 0x02) |
| 13 | Transport | Stop | HID button bit 8 (byte 2, mask 0x01) |
| 14 | Encoders | Left Arrow | HID report 0x0f byte 1 = knob page (either arrow toggles page 0 ↔ 1; page 1 moves knob 1 from CC14 to CC22) |
| 15 | Encoders | Right Arrow | HID report 0x0f byte 1 = knob page (either arrow toggles page 0 ↔ 1; page 1 moves knob 1 from CC14 to CC22) |
| 16 | Encoders | Encoder 1 | MIDI CC14 ch1 (Port 1) [56..127] |
| 17 | Encoders | Encoder 2 | MIDI CC15 ch1 (Port 1) [41..87] |
| 18 | Encoders | Encoder 3 | MIDI CC16 ch1 (Port 1) [79..127] |
| 19 | Encoders | Encoder 4 | MIDI CC17 ch1 (Port 1) [75..127] |
| 20 | Encoders | Encoder 5 | MIDI CC18 ch1 (Port 1) [22..73] |
| 21 | Encoders | Encoder 6 | MIDI CC19 ch1 (Port 1) [33..77] |
| 22 | Encoders | Encoder 7 | MIDI CC20 ch1 (Port 1) [73..127] |
| 23 | Encoders | Encoder 8 | MIDI CC21 ch1 (Port 1) [68..118] |
| 24 | Navigate | Browse | HID button bit 4 (byte 1, mask 0x10) |
| 25 | Navigate | Instance | HID button bit 5 (byte 1, mask 0x20) |
| 26 | Navigate | Back | HID button bit 14 (byte 2, mask 0x40) |
| 27 | Navigate | Left | HID button bit 13 (byte 2, mask 0x20) |
| 28 | Navigate | Knob | HID button bit 32 (byte 5, mask 0x01)<br>HID encoder, byte 6 low nibble (+9 steps) |
| 29 | Navigate | Up | HID button bit 15 (byte 2, mask 0x80) |
| 30 | Navigate | Down | HID button bit 12 (byte 2, mask 0x10) |
| 31 | Navigate | Preset Up | HID button bit 1 (byte 1, mask 0x02) |
| 32 | Navigate | Preset Down | HID button bit 3 (byte 1, mask 0x08) |
| 33 | Navigate | Enter | HID button bit 2 (byte 1, mask 0x04) |
| 34 | Navigate | Right (second “Down” in the list) | HID button bit 11 (byte 2, mask 0x08) |
