# PrimoKKMK1Bridge

Turns every control on a Komplete Kontrol S-series MK1 (S25/S49/S61/S88) into MIDI on a virtual port,
**Primo Komplete Kontrol MK1**, with no Native Instruments software running. Keys, pitch strip and mod strip keep
coming from the keyboard's own MIDI port (*KOMPLETE KONTROL S61 Port 1*), unchanged, and are also merged into
**Primo Komplete Kontrol MK1**, so a DAW track that can only take one MIDI input gets both keys and controls from it
(`keyboardSource`). Don't give a track both ports, or *All MIDI inputs*: it would get every note twice.

How: on connect, PrimoKKMK1Bridge sends the keyboard the same 3-byte HID "init" (`a0 00 00`) that NI's software
and DrivenByMoss send. That switches it from MIDI mode to native mode, where every button, knob touch
and knob turn is reported over USB HID. PrimoKKMK1Bridge translates those reports into MIDI CCs. Protocol
details are in [NOTES.md](../doc/NOTES.md).

**Every control's job and CC in every mode, on one page:** [CONTROLS.md](../doc/CONTROLS.md).

## Build and run

```bash
mkdir -p build && swiftc -O bridge/Sources/*.swift -o build/PrimoKKMK1Bridge
```

```bash
build/PrimoKKMK1Bridge --config bridge/PrimoKKMK1Bridge.json --verbose
```

`--verbose` prints every message it sends. Leave it running while you work; Ctrl-C quits.

The source is in [Sources/](Sources/), one file per area:

| File | What's in it |
|---|---|
| `main.swift` | Command line, replay mode, startup: the USB device watcher, sleep/wake and Ctrl-C handling, and the restart when the config file changes |
| `Hardware.swift` | The keyboard's USB IDs, HID report IDs, button bits and light slots |
| `Config.swift` | Every config key, its default, and validation |
| `MIDIPorts.swift` | The virtual MIDI port, DAW feedback, and the keyboard's keys merged in |
| `Bridge.swift` | The bridge's state, the keyboard's connection, and HID reports turned into MIDI or REAPER commands |
| `Bridge+Lights.swift` | The button lights |
| `Bridge+Displays.swift` | What the displays show in each mode and view |
| `Bridge+Reaper.swift` | REAPER events, and the Komplete Kontrol view's per-page knob memory |
| `Displays.swift` | The displays' 16-segment font and HID reports |
| `OSC.swift` | OSC over UDP, the link to REAPER |
| `ReaperModel.swift` | REAPER commands, action IDs, track and send strips, views |
| `ReaperSession.swift` | The REAPER session: handshake, project state, commands and knob turns |

Good to know:
- **After quitting, the keyboard stays in native mode** (its knobs send nothing) until you unplug and replug it.
- Unplugging and replugging while PrimoKKMK1Bridge runs is fine: it re-sends the init on reconnect, and also after the Mac wakes from sleep.
- If the knobs ever go quiet while PrimoKKMK1Bridge is running, press a page arrow above the knobs. In MIDI mode that
  sends a page report, which PrimoKKMK1Bridge spots, and it switches the keyboard back to native mode.
- On quit, PrimoKKMK1Bridge turns the button lights off and blanks the displays.
- **Saved config changes apply by themselves.** PrimoKKMK1Bridge checks its `--config` file every second. When it
  changes and is valid, the bridge restarts in place (same terminal, same arguments) with the new settings,
  which takes a moment. A file it can't use is logged and ignored, and the bridge keeps its current settings.
  The DAW sees the MIDI port drop out briefly during the restart.

## Editor

**PrimoKKMK1Bridge Editor** is a Mac app for changing the assignments without editing JSON. It shows a drawing
of the keyboard: click a button, knob or strip, and the inspector beside it shows what it does and lets you
change it. It has four pages:

- **MIDI:** the CC each control sends.
- **REAPER:** the REAPER command each button runs, alone and with Shift, and the MIDI CC of any button that sends one in REAPER mode.
- **Komplete Kontrol:** the Komplete Kontrol view's CCs, and its page and preset buttons.
- **Settings:** the port name, channels, keys merge, lights, displays and REAPER connection.

REAPER mode is switched on and off on the Settings page. With it off, the editor shows the MIDI page; with it on, the REAPER and Komplete Kontrol pages instead.

```bash
editor/build.sh
```

```bash
open build/PrimoKKMK1Editor.app
```

It opens `bridge/PrimoKKMK1Bridge.json` (File ▸ Open Config… for another file) and checks every change with the
bridge's own rules. If something can't work, the status bar says why and Save stays off. **Save** (⌘S) writes
the file, and a running bridge picks it up within a second or two. The toolbar shows whether the bridge is
running (whether its MIDI port exists).

Requires macOS 14 or later. The app is signed for this Mac only (ad hoc), not notarized.

## REAPER mode

With `"reaper": {"enabled": true}` in the config, PrimoKKMK1Bridge also talks to REAPER over OSC (REAPER's own
control-surface protocol) and turns the keyboard into a small mixer with three views. **Instance** steps
through them: **Mix → Track → Komplete Kontrol → Mix**. The button lights are single-colour, so the Instance
light shows the view by brightness: off in Mix, half in Track, full in Komplete Kontrol.

**Mix view** (the default): the 8 knobs are the volumes of 8 tracks. **Page ◀ / ▶** (next to the knobs) scroll
through the project's tracks 8 at a time. Each display shows a track's name, its volume and a bar; the left
display shows *MIX* and which tracks are on the knobs (*9-16*). Knobs past the last track stay blank. Hold
Shift and turn a knob to reset that track's volume to 0 dB.

**Track view:** the knobs control the selected track:

| Knob | 1 | 2 | 3 | 4 | 5 | 6–8 |
|---|---|---|---|---|---|---|
| Page 1 | Volume | Pan | Mute | Solo | Record arm | Sends 1–3 |
| Page 2, 3 … (**Page ▶**) | Sends 4–11, 12–16 … | | | | | |

Mute, solo and record arm are switched by turning the knob: a little to the right turns it on, to the left
off. The record-arm display also shows the record monitoring (*ON MON*, *off AUTO*). **Hold Shift** and:

- turn **the record-arm knob** to switch record monitoring on (right) or off (left); while Shift is held its
  display shows *MONITOR* and the monitoring state,
- turn **the pan knob** to snap the pan straight back to centre,
- turn **the volume knob** to reset the volume to 0 dB.

Only sends that are routed somewhere appear, in order, each showing the track it sends to and the send level;
the remaining knobs stay blank. The left display shows the track and *TRK n*, or the page (*PAGE 2/2*).

**Komplete Kontrol view:** the knobs and navigation buttons send fixed MIDI CCs on **Primo Komplete Kontrol MK1**
(channel 1), an NKS-style assignment like the Novation Launchkey MK4's, for Komplete Kontrol:

| Control | CC | | Control | CC |
|---|---|---|---|---|
| Knobs 1–8 | 21–28 | | Navigate ▲ / ▼ | 41 / 40 |
| Preset ▲ / ▼ | 37 / 36 | | Navigate ◀ / ▶ | 42 / 43 |

The knobs send absolute values (0–127) and the buttons 127 on press and 0 on release.

**No jumps when paging (per-page memory):** Komplete Kontrol reads these CCs as absolute positions, so a
knob has to start from somewhere when you change page. PrimoKKMK1Bridge follows KK's page from your
**Navigate ◀ / ▶** presses (`pageButtons`) and remembers where each knob was left on each page of each track;
back on a page, the knobs carry on from there. A page you haven't used yet starts from the middle (64), so
its first turn can still jump, as can a parameter changed with the mouse. **Preset ▲ / ▼** (`presetButtons`)
load a new sound, so that track's remembered values are dropped and the page goes back to 1. KK's page count
isn't known to the bridge: pressing ▶ past the last page puts the bridge's page ahead of KK's until the next
preset change. Relative knob values would avoid all this, but KK's template takes them as positions.

**Displays:** *KOMPLETE* and the page (*PAGE 2*) on the left; each knob's CC and the value it last sent, with a bar.
Komplete Kontrol's curated NKS pages (which parameter is on which knob, and its name) aren't available to the
bridge: the KK plugin only gives REAPER the instrument's full parameter list, in the plugin's own order, and
sends its page layout only to NKS keyboards it supports itself. `hostParameters: true` shows that full list
anyway, 8 per page, but it doesn't line up with KK's knobs and makes REAPER send thousands of messages. Everything else keeps its job from the other
views (transport, Shift shortcuts, Browse, Back, Enter …); Page ◀ / ▶ do nothing here. For Komplete Kontrol to
get these, the track with the Komplete Kontrol plugin needs **Primo Komplete Kontrol MK1** as its MIDI input (which also
carries the keys) and must be record-armed or monitored; CCs, the knob channel and the relative/absolute
mode can be changed under `reaper.kompleteKontrol`.

**In all views:**

| Control | Does |
|---|---|
| Navigate ▲ / ▼ (under the big knob), turning the Navigate knob | ▲ selects the next track (number up), ▼ the previous one (in the Komplete Kontrol view ▲ / ▼ send their CCs instead); turning the knob scrolls through tracks. While you switch, the displays show only *TRK* and the track number (left) and its name across the others; the knobs' values appear 2 seconds after you stop (`reaper.trackNameSeconds`), or as soon as you touch a knob. In track view the track also becomes REAPER's selected track (only it) and is scrolled into view (`reaper.mirrorSelection`) |
| Touch a knob | Frames its value bar while the display updates in place (the other displays stay as they are, so you can adjust several at once), and tells REAPER the fader is touched (for *Touch* automation) |
| Play, Stop, Rec, Loop, ◀◀, ▶▶ | REAPER's transport; Play, Rec and Loop light up with REAPER's state |
| Shift + Rec | Metronome on / off; while Shift is held, the Rec light shows whether it's on |
| Shift + Loop | Record mode: switches between normal and time-selection auto-punch, and shows the new mode on the displays. While Shift is held, the Loop light is on in auto-punch. REAPER doesn't report the record mode over OSC, so this follows the last mode set from the keyboard: if you change it in REAPER, one extra press brings them back in step |
| Shift + Stop | Go to the start of the project |
| Shift + Back | Redo |
| Shift + Browse | Close the selected track's plugin windows |
| Shift + Enter | Open REAPER's Render dialog (*File: Render project to disk...*); click *Render* there |
| Shift + ◀◀ / ▶▶ | Go to the previous / next marker (the project start / end if there's none) |
| Shift + anything else | The MIDI CC layer on channel 2, exactly as in plain mode, except the volume, pan and record-arm knobs: Shift + a volume knob resets it to 0 dB, Shift + the pan knob centres the pan, Shift + the record-arm knob switches record monitoring |
| Back | Undo (REAPER's *Edit: Undo*); Shift + Back: redo |
| Browse | Opens the selected track's first plugin window; each press closes it and opens the next one (after the last, back to the first). The displays show which (*FX 2/3* and its name). Lit while a plugin window of the track is open |
| Pressing the big Navigate knob | MIDI panic: REAPER's *Send all-notes-off and all-sounds-off to all MIDI outputs/plug-ins*; the displays show *PANIC* for a moment |
| Enter | Save the project (REAPER's *File: Save project*) |
| Scale / Arp | Load REAPER screenset (window set) 1 / 2; the displays show *SCREEN · SET 1* and the screenset's name on the third display |
| Preset ▲ / ▼, Navigate ◀ / ▶, Octave −/+ | Their MIDI CCs on channel 1, for MIDI learn (Preset and Navigate: the Komplete Kontrol CCs in that view) |

The selected track also follows the track you click in REAPER (`followSelectedTrack`). Send levels and pages
cover up to 16 sends per track; the master track isn't on the knobs.

### Set up REAPER (once)

1. **Preferences → Control/OSC/web → Add**, Control surface mode **OSC (Open Sound Control)**:
   - Device name: `PrimoKKMK1Bridge`, Pattern config: **Default**
   - Mode: **Configure device IP + local port**
   - Device port `9000`, Device IP `127.0.0.1`, Local listen port `8000`
2. **Preferences → MIDI Devices:** enable **Primo Komplete Kontrol MK1** for input. It carries the keys as well as the
   bridge's CCs, so set the **Komplete Kontrol track's input to Primo Komplete Kontrol MK1** (one input: keys, strips
   and the Komplete Kontrol view's CCs). For tracks that should only get the keys, use *KOMPLETE KONTROL S61
   Port 1* instead, so the bridge's CCs don't get recorded into their items. Never *All MIDI inputs* (or
   both ports): notes would arrive twice.
3. To have the keys play whichever track you select, turn on **Automatic record-arm when track selected**
   for those tracks (right-click a track's record-arm button).

Until REAPER answers, the displays say *waiting for OSC from REAPER*.

REAPER only sends a value over OSC when it changed since it last sent it, so on start-up PrimoKKMK1Bridge runs
REAPER's *Control surface: Refresh all surfaces* action (command ID 41743) to get the whole project. Your
other control surfaces (MCU, FaderPort, HUI) get refreshed at the same moment.

REAPER also reports every slot whether it's used or not: tracks past the last one come as "Track 12" at
-inf dB with 0% width, and unused sends as "Send 3" at -inf dB. PrimoKKMK1Bridge leaves those out. (A real track
named exactly like that, at -inf dB and 0% width, would be left out too.)

To see what REAPER sends, add `--log-osc` (the clock and meters are left out).

## Displays

The nine displays above the knobs show what the knobs do. In plain mode: the CC number, its value and a bar
for each knob (the Shift layer's while Shift is held). In REAPER mode: see above. Set `"displays": false` to
leave them alone.

## Button lights

In native mode the computer drives the 21 button lights (Octave −/+ and the Navigate click have none).

- Mapped buttons glow dimly (`lightIdleBrightness`), and a button lights fully while you hold it.
- **DAW feedback:** PrimoKKMK1Bridge also creates a MIDI *output* named **Primo Komplete Kontrol MK1**. When the DAW sends a
  button's CC there, any value above 0 lights it and 0 dims it again. So if your DAW sends the transport
  state on CC102 (Play), CC104 (Rec) and CC105 (Loop), those lights follow it.
- Feedback on channel 2 sets the Shift-layer lights, shown while Shift is held. A button with no
  channel-2 feedback keeps showing its channel-1 state.
- Knob CCs sent back on that output update PrimoKKMK1Bridge's knob values, so in `absolute` mode a knob carries on
  from the DAW's value instead of jumping.
- Try it without a DAW: `build/midisend "Primo Komplete Kontrol MK1" 1 102 127` lights Play, and `... 1 102 0` dims it.

## Default mapping (all on channel 1)

| Control | CC | | Control | CC |
|---|---|---|---|---|
| Play | 102 | | Browse | 115 |
| Stop | 103 | | Instance | 116 |
| Rec | 104 | | Back | 117 |
| Loop | 105 | | Enter | 118 |
| Rewind | 106 | | Preset Up | 119 |
| Fast Forward | 107 | | Preset Down | 85 |
| Shift | 108 | | Navigate Up / Down / Left / Right | 86 / 87 / 88 / 89 |
| Scale | 109 | | Navigate knob click | 90 |
| Arp | 110 | | Navigate knob turn | 30 (relative) |
| Octave − / + | 111 / 112 | | Navigate knob touch | 31 |
| Page Left / Right | 113 / 114 | | Knobs 1–8 turn | 14–21 (absolute) |
| | | | Knobs 1–8 touch | 22–29 |

- Buttons send 127 on press and 0 on release. Touch sends 127 when touched and 0 when released.
- **Shift layer:** while Shift is held, buttons, knobs and the Navigate knob send on **channel 2** instead,
  which gives every control a second assignment. A release always goes out on the same channel as its press.
- Octave −/+ still transpose the keyboard as well as sending their CC. Set them to `null` if you don't want the CC.

## Configuration

Use the [Editor](#editor), or edit [PrimoKKMK1Bridge.json](PrimoKKMK1Bridge.json) directly. Every key is
optional; anything you leave out keeps its default. A running bridge applies a saved change by itself.
`build/PrimoKKMK1Bridge --print-default-config` prints the full default file.

| Key | Meaning |
|---|---|
| `portName` | Name of the virtual MIDI port |
| `channel` | Base MIDI channel, 1–16 |
| `shiftChannel` | Channel used while Shift is held, or `null` to make Shift a plain button |
| `buttons` | Button name → CC number, or `null` to silence that button |
| `knobCCs` | 8 CCs for knobs 1–8 |
| `knobMode` | `absolute` (0–127, starts at 64), `relative-binary-offset` (64 ± n), `relative-twos-complement` (1–63 up, 127–65 down), `relative-signed-bit` (1–63 up, 65–127 down) |
| `knobStepsPerCC` | Knob resolution: raw position units (the knobs report 0–999, wrapping) per MIDI step. Default 4; higher = finer and slower |
| `knobTouchCCs` | 8 CCs for knob touch, or `[]` to turn touch off |
| `navigateTurnCC`, `navigateTurnMode` | Navigate knob rotation, same modes as `knobMode` |
| `navigateTouchCC` | Navigate knob touch, or `null` |
| `lights` | `true` to drive the button lights, `false` to leave them alone |
| `lightBrightness` | Brightness of a lit button, 0–255 (default 127; the HID descriptor declares 0–127, DrivenByMoss uses 255 for "bright") |
| `lightIdleBrightness` | Glow of a mapped button that's off, 0–255 (default 6; 0 = dark) |
| `displays` | `true` to drive the displays above the knobs |
| `keyboardSource` | Merge the keyboard's own MIDI (keys, strips, pedals) into the virtual port: `"auto"` (default: the keyboard's *Port 1*, found again after a replug), a MIDI source name, or `null` to keep the keys on the keyboard's port only |
| `reaper.enabled` | `true` for REAPER mode |
| `reaper.host`, `reaper.sendPort`, `reaper.receivePort` | Where REAPER is: its IP, its *Local listen port* (default 8000) and its *Device port* (default 9000) |
| `reaper.view` | The view at start: `mix` (default), `track` or `komplete-kontrol` |
| `reaper.followSelectedTrack` | `true`: the selected track follows the track last clicked in REAPER |
| `reaper.knobFullRange` | How far to turn a knob for a fader's full range, in raw knob units (default 600; lower = faster) |
| `reaper.trackNameSeconds` | After a track change, how long only the track's number and name show before the knobs' values (default 2; 0 = only until REAPER has sent the new track's values). Touching a knob ends it early |
| `reaper.mirrorSelection` | `true` (default): in track view, a track picked with ▲ / ▼ or the Navigate knob becomes REAPER's only selected track and is scrolled into view. Clicking tracks in REAPER is never overridden |
| `reaper.resourcePath` | REAPER's resource folder, for the screenset names in `reaper-screensets.ini` (default `~/Library/Application Support/REAPER`) |
| `reaper.kompleteKontrol` | The Komplete Kontrol view: `channel` (default 1), `encoderCCs` (8 CCs, default 21–28), `encoderMode` (same modes as `knobMode`, default `absolute`), and `buttons` (button name → CC; default Preset Up 37, Preset Down 36, Nav Up 41, Nav Down 40, Nav Left 42, Nav Right 43), and `pageButtons` (the two buttons that change Komplete Kontrol's NKS page, previous / next; default `["NavLeft", "NavRight"]`); `hostParameters` (experimental, default `false`, see the Komplete Kontrol view); `presetButtons` (the buttons that load another preset in KK, default `["PresetUp", "PresetDown"]`) |
| `reaper.navigateTurn` | What turning the Navigate knob steps through: `tracks` (default), `pages`, or `null` for its CC |
| `reaper.buttons` | Button name → REAPER command, or `null` to give the button back its CC. Commands: `play`, `stop`, `record`, `repeat`, `rewind`, `forward`, `metronome` (on/off), `record-mode` (normal / time-selection auto-punch), `go-to-start`, `previous-marker`, `next-marker`, `undo`, `redo`, `browse-fx`, `close-fx`, `panic` (all notes off), `save-project`, `render-project`, `screenset:1` … `screenset:10` (load that window set), `previous-track`, `next-track`, `previous-page`, `next-page`, `toggle-view`, `mute`, `solo` (the selected track), or `action:<ID>` to run any REAPER action (right-click it in REAPER's Action List → *Copy selected action command ID*) |
| `reaper.shiftButtons` | The same, for buttons pressed while Shift is held (default: Rec → `metronome`, Loop → `record-mode`, Stop → `go-to-start`, Rewind → `previous-marker`, FastForward → `next-marker`, Back → `redo`, Browse → `close-fx`, Enter → `render-project`). Shift + a button not listed here sends its CC on the Shift channel |

Relative modes suit endless knobs best, but your DAW has to be told which relative format to expect
(for example in Ableton Live's MIDI map, set the control's mode to the matching "Relative" type).
`absolute` works with plain MIDI learn everywhere.

## Tested

2026-11-07 on an S61 MK1 (firmware 72), macOS 26: all 24 buttons, the Shift layer, knobs 1–8 turn and touch,
and Navigate knob turn, touch and click. The last 1,000 messages PrimoKKMK1Bridge logged matched, in order and value
for value, what a separate MIDI client received on the bridge's virtual port (then named *KK S61 Controls*;
`device/tests/bridge_live/`).
Button lights confirmed on the keyboard the same day: dim idle glow, and Play/Rec/Loop lit by feedback sent
with `build/midisend` (brightness 127 / 6).

The displays worked on the keyboard with REAPER 7.61 on 2026-11-07. Mix view (tracks on the knobs) and track
view (volume, pan, mute, solo, sends, track selection) were confirmed with REAPER 7.61 on 2026-11-08, after
adding the start-up refresh, and the same day with unused send and track slots hidden and the number-and-name
display while switching tracks. They were first tested against a simulated REAPER (`tools/fake_reaper.py`,
`device/tests/reaper_sim/`), which, like REAPER, only sends values that changed.

## Testing without the keyboard

`--replay` runs a capture log from `tools/kkmap` through the mapping and prints what would be sent, and the
display contents as text:

```bash
build/PrimoKKMK1Bridge --replay device/tests/native_knobs_results/capture_mapping.log --config bridge/PrimoKKMK1Bridge.json
```

For REAPER mode, start the stand-in REAPER first, then replay with a config that points at it:

```bash
python3 tools/fake_reaper.py --listen 18000 --send 19000 --seconds 8 &
```

```bash
build/PrimoKKMK1Bridge --replay device/tests/reaper_sim/synthetic_reaper_test.log --config device/tests/reaper_sim/reaper_test_config.json
```

`build/PrimoKKMK1Bridge --show-font` draws every character the displays can show.

## Start at login (optional, not installed)

[local.PrimoKKMK1Bridge.plist](local.PrimoKKMK1Bridge.plist) is a LaunchAgent template with this folder's paths. To install it:

```bash
cp bridge/local.PrimoKKMK1Bridge.plist ~/Library/LaunchAgents/
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.PrimoKKMK1Bridge.plist
```

Logs go to `/tmp/PrimoKKMK1Bridge.log`. To remove it, run `launchctl bootout gui/$(id -u)/local.PrimoKKMK1Bridge` and delete the file.
Running from a LaunchAgent hasn't been tested yet.
