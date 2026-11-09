# KKS61 MK1 control map

Captured 2026-11-07 18:09 with `tools/kkmap` from `native_knobs_test.md`. Firmware 72, native mode (init report a0 00 00 sent), no NI software running.

| # | Section | Control | Reports as |
|---|---|---|---|
| 1 | Knobs | Encoder 1 (turn it) | HID button bit 24 (byte 4, mask 0x01)<br>HID knob 1 position (bytes 7-8) (+21 steps) |
| 2 | Knobs | Encoder 2 (turn it) | HID button bit 25 (byte 4, mask 0x02)<br>HID knob 2 position (bytes 9-10) (-82 steps) |
| 3 | Knobs | Encoder 3 (turn it) | HID button bit 25 (byte 4, mask 0x02)<br>HID button bit 26 (byte 4, mask 0x04)<br>HID knob 3 position (bytes 11-12) (+480 steps) |
| 4 | Knobs | Encoder 4 (turn it) | HID button bit 27 (byte 4, mask 0x08)<br>HID knob 4 position (bytes 13-14) (+34 steps) |
| 5 | Knobs | Encoder 5 (turn it) | HID button bit 28 (byte 4, mask 0x10)<br>HID knob 5 position (bytes 15-16) (+212 steps) |
| 6 | Knobs | Encoder 6 (turn it) | HID button bit 29 (byte 4, mask 0x20)<br>HID knob 6 position (bytes 17-18) (+216 steps) |
| 7 | Knobs | Encoder 7 (turn it) | HID button bit 30 (byte 4, mask 0x40)<br>HID knob 7 position (bytes 19-20) (+275 steps) |
| 8 | Knobs | Encoder 8 (turn it) | HID button bit 31 (byte 4, mask 0x80)<br>HID knob 8 position (bytes 21-22) (+386 steps) |
| 9 | Navigate | Click the big Navigate knob straight in (press it, don't turn or tilt) | HID button bit 32 (byte 5, mask 0x01)<br>HID button bit 0 (byte 1, mask 0x01) |
| 10 | Transpose | Oct + | HID button bit 7 (byte 1, mask 0x80)<br>base note 36 → 48 |
| 11 | Transpose | Play one key | MIDI note 48 on ch1 (Port 1) = 38 |
| 12 | Transpose | Oct - | HID button bit 6 (byte 1, mask 0x40)<br>base note 48 → 36 |
