# Komplete Kontrol S61 MK1 — protocol notes

What the keyboard sends and accepts over USB, as worked out here, and at the end what REAPER's OSC does and doesn't
report, and what's been confirmed on hardware.

Device: USB 17cc:1360, firmware 72, USB 2.0 high speed. Interfaces: 0 UAC2 audio control, 1 MIDI (Port 1, Port 2),
2 vendor HID (usage page 0xFF01), 3 DFU runtime. All captures: stock MIDI mode, no NI software running.

## Control map (guided capture 2026-11-07, see BUTTON_MAP.md)

### Already MIDI (Port 1, channel 1)
| Control | Sends |
|---|---|
| Keys | notes |
| Pitch strip | pitch bend |
| Mod strip | CC1 |
| Knobs 1–8 (“Encoder 1–8”) | CC14–CC21, absolute 0–127. No HID report and no touch bit when turned |

### HID only — report 0x01, bytes 1–5 = 40-bit button field (bit n = byte 1 + n/8, mask 1 << n%8)
| Bit | Control | | Bit | Control |
|---|---|---|---|---|
| 1 | Preset Up | | 12 | Navigate Down |
| 2 | Enter | | 13 | Navigate Left |
| 3 | Preset Down | | 14 | Back |
| 4 | Browse | | 15 | Navigate Up |
| 5 | Instance | | 16 | Shift |
| 6 | Oct − (also transposes locally) | | 19 | Loop |
| 7 | Oct + (also transposes locally) | | 22 | RWD |
| 8 | Stop | | 23 | FFW |
| 9 | REC (Count In) | | 32 | Navigate knob touch (flickers while turning) |
| 10 | Play (Restart) | | | |
| 11 | Navigate Right | | | |

- Navigate knob rotation: low nibble of byte 6, 4-bit wrapping counter, +1 per detent clockwise. High nibble unused so far.
- Byte 37: current base note (36 = default; 24 / 12 after Oct −). Updated by the keyboard itself.
- Bytes 7–22: raw knob positions (0–999), refreshed only when some other HID report goes out.

### HID report 0x0f — the page arrows above the knobs = knob page (tests/page_arrow_results)
`0f <page> ff ff`, sent when the page changes. MIDI mode has **two knob pages that wrap**, and the firmware uses
both arrows to switch between them, so either arrow simply toggles the page:

| Page (byte 1) | Knob 1 sends |
|---|---|
| 0 (power-on) | CC14 (knobs 1–8 = CC14–21) |
| 1 | CC22 (knobs 1–8 presumably CC22–29; only knob 1 verified) |

Left and Right have no button bits of their own, so the HID data can't tell which arrow was pressed. Only the
resulting page is visible. Giving them separate functions would need the firmware patch.

### Native (host) mode — switched with output report `a0 00 00` (from DrivenByMoss `Kontrol1UsbDevice.java`, LGPLv3)
Verified on this unit 2026-11-07 (tests/native_mode_results). The device accepted the report (kIOReturnSuccess) and
then reported the buttons MIDI mode hides. DrivenByMoss's button table agrees with every bit captured above.

All verified on this unit (tests/native_mode_results, tests/native_knobs_results):

| Bit | Control |
|---|---|
| 0 | Navigate knob click (also sets touch bit 32) |
| 17 | Scale |
| 18 | Arp |
| 20 | Page Right (arrow above knobs). Own bit; the report 0x0f paging is gone |
| 21 | Page Left |
| 24–31 | Knob 1–8 touch (capacitive; neighbours brush easily, e.g. bit 25 while turning knob 3) |

Every other button keeps its MIDI-mode bit, so the full native map is bits 0–23 buttons, 24–31 knob touch,
32 Navigate knob touch, byte 6 low nibble Navigate knob turn, bytes 7–22 knob positions, byte 37 base note.

What changes in native mode:
- **Knobs stop sending MIDI CCs.** No CC14–29 at all. Their positions come over HID instead: bytes 7–22, u16 0–999
  wrapping, about one report every 10 ms while turning (knob 1: 4 → 350 in about 0.45 s). A bridge must turn these into CCs.
- **Still MIDI on Port 1:** keys (notes), pitch strip (pitch bend), mod strip (CC1).
- **Oct −/+ still transpose** on the keyboard itself (byte 37 base note 36 → 48 → 36; a key then sent note 48).
- The knob 8 anomaly in the first native run was a stray touch on knob 2. On retest, all 8 knobs reported touch and position.
- **Not persistent:** after unplugging and replugging, the keyboard is back in MIDI mode (knob 1 → CC14, page arrows →
  report 0x0f) without anything being sent (tests/replug_results). A bridge must send `a0 00 00` on every connect.
Button LEDs (out 0x80, 21 used of 25: Shift, Scale, Arp, Loop, RWD, FFW, Play, Rec, Stop, Page L/R, Browse,
Preset Up, Instance, Preset Down, Back, Nav Up, Enter, Nav Left, Nav Down, Nav Right) are then host-controlled.

### Silent in MIDI mode — nothing on HID or MIDI
- **Scale (Edit)** and **Arp (Edit)**, alone and with Shift held (Shift+Scale / Shift+Arp only show bit 16).
  Not yet known whether the firmware swallows them, whether they need NI's host handshake, or whether the switches
  are dead. Check: does the button LED react when pressed?

## Other HID reports (from the descriptor; to be confirmed)
- Out 0x80: 25 bytes, button LEDs (0–127 brightness). Out 0x82: 183 bytes = 61 keys × RGB light guide. Out 0xe0: display writes.
- **Light guide (out 0x82), confirmed on the S61 MK1 in native mode (2026-11-11):** 3 bytes per key in the order
  red, green, blue, 0–127 each, key 1 = the lowest key; all 61 keys respond. The LEDs aren't balanced: equal values
  look purple-white, and red ×0.75, green ×1, blue ×0.67 looks neutral (also at half brightness). The lights stay as
  set until the next report.

### Displays (out 0xe0, 248 bytes) — from DrivenByMoss `Kontrol1UsbDevice.java` (LGPLv3); not yet seen on hardware
- Nine displays of 8 characters × 2 rows: one left of knob 1, then one above each knob (72 columns per row).
- One report per row. Header (8 bytes): `00 00 <row> 00 48 00 01 00` (0x48 = 72 columns). Rest zero-padded.
- Row 0 = value bars and decimal points: per column 2 bytes. Byte 1 = bar segment of that column; byte 2 = dots
  (0 none, 253 top row, 254 bottom row, 255 both), except the 8th column of each display, where byte 2 is that
  display's 9th bar segment. A bar segment is 0 (off), 2 (1 step), 1 (2 steps) or 3 (full); +68 draws a frame.
- Rows 1 and 2 = text: 72 characters × 2 bytes, 16-segment bitmaps. Low byte: outer ring clockwise from the
  top-left: a1 a2 b c d2 d1 e f (bits 0–7). High byte: inner segments in reading order: h (upper-left diagonal),
  i (upper centre), j (upper-right diagonal), g1, g2 (middle halves), k (lower-left diagonal), l (lower centre),
  m (lower-right diagonal). Worked out from DrivenByMoss's glyph table; PrimoKKMK1Bridge draws its own glyphs with it.
- Confirmed on the S61 MK1 (2026-11-07/08): text, dots and value bars display as described.
- **The firmware blanks the displays by itself when Preset Up / Preset Down is pressed** in native mode (seen
  2026-11-08). A host that only resends changed rows must resend everything after such a press; PrimoKKMK1Bridge
  resends all three rows 50 ms after any button press or release, which fixed it.
- Feature 0xd0–0xdf: 512-byte read window into a config/factory block (serials, calibration). Feature 0xf8: firmware version 72 + brightness settings.

## REAPER over OSC (REAPER 7.61, Default.ReaperOSC patterns)

- **Only changes are sent.** REAPER sends a value only when it differs from what it last sent to that address, so a
  surface that starts after REAPER hears nothing about tracks, pans or sends that haven't moved. The bridge runs
  *Control surface: Refresh all surfaces* (command ID 41743) on start-up to get the whole project; other control
  surfaces refresh at the same moment. `tools/fake_reaper.py` behaves the same way.
- **Unused slots are reported too.** Tracks past the last come as "Track 12" at -inf dB (volume/db -150) with 0%
  width (pan2 0.5), and unused sends as "Send 3" at -inf dB. The bridge leaves those out; a real track named exactly
  like that, at -inf dB and 0% width, would be left out too.
- **Bank tracks** (`/track/@/…`) have volume, pan, their `/str` texts, and volume and pan touch
  (`/track/@/volume/touch`, `/track/@/pan/touch`).
- **Not reported:** the record mode (normal or time-selection auto-punch), so the bridge follows the last mode it set,
  and track colours. For the light guide, `reaper/PrimoKKMK1Bridge_TrackColor.lua` runs inside REAPER and sends the
  selected track's colour to the bridge's MIDI output as SysEx, every time it changes and every 2 seconds:
  `F0 7D 50 4B 01 rr gg bb F7` (0–127 each; 7D is the non-commercial manufacturer ID), or `F0 7D 50 4B 02 F7` for no
  colour. It sends the no-colour message when REAPER quits.
- **MIDI Editor actions** have their own IDs, which overlap the main section's, so they go out as
  `/midiaction <ID>` rather than `/action <ID>`.
- `--log-osc` prints everything REAPER sends, apart from the clock and meters that stream during playback.

## Confirmed on hardware

- **2026-11-07, S61 MK1 (firmware 72), macOS 26:** all 24 buttons, the Shift layer, knobs 1–8 turn and touch, and
  Navigate knob turn, touch and click. The last 1,000 messages the bridge logged matched, in order and value for value,
  what a separate MIDI client received on the bridge's virtual port (`device/tests/bridge_live/`). The button lights
  the same day: dim idle glow, and Play/Rec/Loop lit by feedback sent with `build/midisend`.
- **2026-11-07/08, REAPER 7.61:** the displays; Mix view and Track view (volume, pan, mute, solo, sends, track
  selection), after adding the start-up refresh; unused send and track slots hidden; the number-and-name display
  while switching tracks. All first tested against `tools/fake_reaper.py` (`device/tests/reaper_sim/`).
- **2026-11-11/12:** the light guide's track colours, white balance and brightness; Shift + knob panning in Mix view;
  the Navigate knob's switch to Track view, and track selection in the Komplete Kontrol view; the light guide's
  startup animation, purple while waiting and red on an OSC error.
