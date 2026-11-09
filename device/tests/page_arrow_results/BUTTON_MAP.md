# KKS61 MK1 control map

Captured 2026-11-07 17:55 with `tools/kkmap` from `page_arrow_test.md`. Firmware 72, stock MIDI mode, no NI software running.

| # | Section | Control | Reports as |
|---|---|---|---|
| 1 | Baseline | Encoder 1 (turn it) | MIDI CC14 ch1 (Port 1) [0..127] |
| 2 | Left twice | Left Arrow | HID report 0x0f byte 1 → 1 |
| 3 | Left twice | Encoder 1 (turn it) | MIDI CC22 ch1 (Port 1) [1..127] |
| 4 | Left twice | Left Arrow | HID report 0x0f byte 1 → 0 |
| 5 | Left twice | Encoder 1 (turn it) | MIDI CC14 ch1 (Port 1) [8..127] |
| 6 | Right twice | Right Arrow | HID report 0x0f byte 1 → 1 |
| 7 | Right twice | Encoder 1 (turn it) | MIDI CC22 ch1 (Port 1) [6..127] |
| 8 | Right twice | Right Arrow | HID report 0x0f byte 1 → 0 |
| 9 | Right twice | Encoder 1 (turn it) | MIDI CC14 ch1 (Port 1) [0..92] |
| 10 | Perform with Shift | Hold Shift and press Scale, then let go of both | HID button bit 16 (byte 3, mask 0x01) |
| 11 | Perform with Shift | Hold Shift and press Arp, then let go of both | HID button bit 16 (byte 3, mask 0x01) |
