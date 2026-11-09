# KKS61 MK1 control map

Captured 2026-11-07 18:04 with `tools/kkmap` from `native_mode_test.md`. Firmware 72, native mode (init report a0 00 00 sent), no NI software running.

| # | Section | Control | Reports as |
|---|---|---|---|
| 1 | Perform | Scale (Edit) | HID button bit 17 (byte 3, mask 0x02) |
| 2 | Perform | Arp (Edit) | HID button bit 18 (byte 3, mask 0x04) |
| 3 | Page arrows | Left Arrow | HID button bit 21 (byte 3, mask 0x20) |
| 4 | Page arrows | Right Arrow | HID button bit 20 (byte 3, mask 0x10) |
| 5 | Knobs | Encoder 1 (turn it) | HID button bit 24 (byte 4, mask 0x01)<br>HID knob 1 position (bytes 7-8) (+346 steps)<br>HID button bit 25 (byte 4, mask 0x02) |
| 6 | Knobs | Encoder 8 (turn it) | HID button bit 25 (byte 4, mask 0x02) |
| 7 | Navigate | Push the Navigate knob down (press it once) | HID button bit 12 (byte 2, mask 0x10) |
| 8 | Strips and keys | Pitch Strip | MIDI pitch bend ch1 (Port 1) [2080..16383] |
| 9 | Strips and keys | Mod Strip | MIDI CC1 ch1 (Port 1) [1..110] |
| 10 | Strips and keys | Play one key | MIDI note 43 on ch1 (Port 1) = 14 |
