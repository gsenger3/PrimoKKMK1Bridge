# Komplete Kontrol MK1 S controls with PrimoKKMK1Bridge

## Modes at a glance

The S Series MK1 works three ways. Only native mode, which PrimoKKMK1Bridge switches on, gets every button and the displays.

| Mode | How you get it | MIDI port | What the controls do |
| --- | --- | --- | --- |
| MIDI mode | Keyboard on its own: power-on or replug, PrimoKKMK1Bridge not running | KOMPLETE KONTROL S Series Port 1 | Keys, strips and the 8 knobs send MIDI. Most buttons send nothing |
| Native mode, CC mapping | PrimoKKMK1Bridge running, `reaper.enabled` false | Primo Komplete Kontrol MK1 (keys merged in) | Every button, knob, touch and the Navigate knob sends a CC. Shift gives a second layer on channel 2 |
| Native mode, REAPER | PrimoKKMK1Bridge running, `reaper.enabled` true | Primo Komplete Kontrol MK1 plus OSC to REAPER | Transport and editing buttons run REAPER actions. The knobs work in three views: Mix, Track and Komplete Kontrol |

The keys, pitch strip and mod strip work the same in every mode:

| Control | Sends |
| --- | --- |
| Keys | Notes, channel 1 |
| Pitch strip | Pitch bend |
| Mod strip | CC1 |
| Octave − / + | Transpose the keys on the keyboard itself (also a CC in native mode) |

In native mode these come through both ports: Port 1 and Primo Komplete Kontrol MK1. Give a DAW track one of them, never both and never *All MIDI inputs*, or every note arrives twice.

After PrimoKKMK1Bridge quits, the keyboard stays in native mode and its knobs go quiet until you unplug and replug it.

## MIDI mode (keyboard on its own)

On its own the keyboard sends only the keys, the two strips and the 8 knobs, all on channel 1 of *KOMPLETE KONTROL S Series Port 1*. The displays stay blank.

| Control | Sends |
| --- | --- |
| Knobs 1–8, page 1 (at power-on) | CC14–21, absolute 0–127 |
| Knobs 1–8, page 2 | CC22–29 (only knob 1 confirmed) |
| Page ◀ / ▶ (arrows next to the knobs) | Either arrow switches between knob pages 1 and 2. No MIDI of its own |
| Keys, pitch strip, mod strip, Octave − / + | As in *Modes at a glance* |
| Every other button | Nothing over MIDI. Scale and Arp are silent everywhere in this mode |
| Knob touch, Navigate knob turn and touch | Nothing over MIDI |

## Native mode: CC mapping

With REAPER mode off, every control sends a CC on *Primo Komplete Kontrol MK1*, channel 1. Holding Shift moves the buttons, knob turns and the Navigate knob turn to channel 2, so each gets a second assignment.

| Control | CC | Values | With Shift held |
| --- | --- | --- | --- |
| Play | 102 | 127 press, 0 release | Same CC, channel 2 |
| Stop | 103 | 127 / 0 | Channel 2 |
| Rec | 104 | 127 / 0 | Channel 2 |
| Loop | 105 | 127 / 0 | Channel 2 |
| Rewind ◀◀ | 106 | 127 / 0 | Channel 2 |
| Fast forward ▶▶ | 107 | 127 / 0 | Channel 2 |
| Shift | 108 | 127 / 0 | Always channel 1 |
| Scale | 109 | 127 / 0 | Channel 2 |
| Arp | 110 | 127 / 0 | Channel 2 |
| Octave − / + | 111 / 112 | 127 / 0, and the keys transpose | Channel 2 |
| Page ◀ / ▶ (next to the knobs) | 113 / 114 | 127 / 0 | Channel 2 |
| Browse | 115 | 127 / 0 | Channel 2 |
| Instance | 116 | 127 / 0 | Channel 2 |
| Back | 117 | 127 / 0 | Channel 2 |
| Enter | 118 | 127 / 0 | Channel 2 |
| Preset ▲ / ▼ | 119 / 85 | 127 / 0 | Channel 2 |
| Navigate ▲ / ▼ / ◀ / ▶ | 86 / 87 / 88 / 89 | 127 / 0 | Channel 2 |
| Navigate knob press | 90 | 127 / 0 | Channel 2 |
| Navigate knob turn | 30 | Relative, 64 ± steps | Channel 2 |
| Navigate knob touch | 31 | 127 touched, 0 released | Always channel 1 |
| Knobs 1–8 turn | 14–21 | Absolute 0–127, starting at 64 | Channel 2, its own values |
| Knobs 1–8 touch | 22–29 | 127 touched, 0 released | Always channel 1 |

A release always goes out on the channel of its press, even if Shift was let go first. Knob values the DAW sends back on the *Primo Komplete Kontrol MK1* output move the bridge's knob values, so the next turn carries on from there.

## REAPER mode: buttons in every view

In REAPER mode most buttons run REAPER commands over OSC. A Shift combination not listed below sends that button's CC on channel 2, as in the CC mapping. **Instance** steps through the views: Mix → Track → Komplete Kontrol → Mix.

| Button | Press | Shift + press |
| --- | --- | --- |
| Play | Play | CC102, channel 2 |
| Stop | Stop | Go to the start of the project |
| Rec | Record | Metronome on / off |
| Loop | Repeat on / off | Record mode: normal ↔ time-selection auto-punch |
| Rewind ◀◀ | Rewind | Previous marker |
| Fast forward ▶▶ | Fast forward | Next marker |
| Back | Undo | Redo |
| Enter | Save project | Open the Render dialog (click *Render* there) |
| Browse | Open the selected track's first plugin window; each press opens the next one | Close the selected track's plugin windows |
| Navigate knob press | MIDI panic: all notes off, all sounds off | CC90, channel 2 |
| Scale | Load screenset 1 | CC109, channel 2 |
| Arp | Load screenset 2 | CC110, channel 2 |
| Instance | Next view | CC116, channel 2 |
| Navigate ▲ / ▼ | Next / previous track (Komplete Kontrol view: CC41 / 40) | CC86 / 87, channel 2 |
| Navigate knob turn | Scroll through tracks | CC30, channel 2 |
| Navigate ◀ / ▶ | CC88 / 89, channel 1 (Komplete Kontrol view: CC42 / 43) | CC88 / 89, channel 2 |
| Preset ▲ / ▼ | CC119 / 85, channel 1 (Komplete Kontrol view: CC37 / 36) | CC119 / 85, channel 2 |
| Page ◀ / ▶ | Mix: previous / next 8 tracks. Track: previous / next knob page. Komplete Kontrol: CC42 / 43, like Navigate ◀ / ▶ | CC113 / 114, channel 2 |
| Octave − / + | Transpose the keys, plus CC111 / 112, channel 1 | CC111 / 112, channel 2 |
| Shift | Holds the Shift layer; also sends CC108, channel 1 | — |

When you change track, the displays show only *TRK* with the number and the track name for 2 seconds, then the knob values. Touching a knob ends this early. The selected track also follows the track you click in REAPER.

## REAPER Mix view (default)

The 8 knobs are the volumes of 8 tracks; **Page ◀ / ▶** move them 8 tracks at a time. The Instance light is off.

| Control | Does |
| --- | --- |
| Knobs 1–8 turn | Volume of the 8 tracks on the knobs. 600 raw knob units cover the fader's full range |
| Shift + knob turn | Reset that track's volume to 0 dB |
| Knob touch | Frames that knob's value bar and tells REAPER the fader is touched, for *Touch* automation |
| Page ◀ / ▶ | Previous / next bank of 8 tracks |

The left display shows *MIX* and the tracks on the knobs, such as *9-16*. Each knob's display shows the track's name, its volume and a bar. Knobs past the last track stay blank, and the master track isn't on the knobs.

## REAPER Track view

The knobs control the selected track, and the Instance light is at medium brightness. Picking a track with Navigate ▲ / ▼ or the Navigate knob also makes it REAPER's only selected track and scrolls it into view.

| Knob | Page 1 | Shift + turn on page 1 |
| --- | --- | --- |
| 1 | Volume | Reset to 0 dB |
| 2 | Pan (display reads *CENTER* at centre) | Snap to centre |
| 3 | Mute: turn right for on, left for off | CC16, channel 2 |
| 4 | Solo: right on, left off | CC17, channel 2 |
| 5 | Record arm: right on, left off | Record monitoring: right on, left off |
| 6–8 | Sends 1–3 | CC19–21, channel 2 |

**Page ▶** moves the knobs to the next 8 sends (page 2: sends 4–11, page 3: sends 12–16); **Page ◀** goes back. Only sends that are routed somewhere appear, in order, and the remaining knobs stay blank. Shift + a send knob sends its knob CC (14–21) on channel 2.

The left display shows the track name and *TRK n*, or the page, such as *PAGE 2/2*. Each send shows the track it feeds and its level. The record-arm display also shows the monitoring (*ON MON*, *off AUTO*); while Shift is held it shows *MONITOR* and the monitoring state.

## REAPER Komplete Kontrol view

The knobs and eight navigation buttons send fixed CCs on *Primo Komplete Kontrol MK1*, channel 1, for Komplete Kontrol's NKS MIDI template. The Instance light is at full brightness. All other buttons keep their jobs from the table above.

| Control | CC | Values | Also |
| --- | --- | --- | --- |
| Knobs 1–8 turn | 21–28 | Absolute 0–127 | One set of values for every page, track and preset |
| Preset ▲ | 37 | 127 press, 0 release | Next preset in KK |
| Preset ▼ | 36 | 127 / 0 | Previous preset in KK |
| Navigate ▲ | 41 | 127 / 0 | No track change in this view |
| Navigate ▼ | 40 | 127 / 0 | No track change in this view |
| Navigate ◀ | 42 | 127 / 0 | Previous NKS page in KK |
| Navigate ▶ | 43 | 127 / 0 | Next NKS page in KK |
| Shift + knob turn | 14–21, channel 2 | Absolute | The CC mapping's Shift layer |
| Page ◀ / ▶ (next to the knobs) | 42 / 43 | 127 / 0 | Previous / next NKS page in KK, the same as Navigate ◀ / ▶ |

Like Novation's Launchkey, the bridge doesn't follow KK's pages or presets, whose parameter names and values aren't available to it. It keeps one set of 8 knob values, starting at 64, and each knob carries on from the value it last sent. A knob can still jump when that value doesn't match the parameter it now controls, after a page or preset change or a mouse edit.

The left display shows *KOMPLETE KONTROL*; each knob's display shows *ENCODER* and its number (1–8), with a bar of the value it last sent. For KK to receive all this, its REAPER track needs *Primo Komplete Kontrol MK1* as input and must be record-armed or monitored.

## Lights and displays

The lights and displays are driven only in native mode. Octave − / + and the Navigate knob have no light.

| What | CC mapping | REAPER mode |
| --- | --- | --- |
| Button lights | Mapped buttons glow dimly and light fully while held. A CC sent back to the *Primo Komplete Kontrol MK1* output lights its button (any value above 0) or dims it (0); channel 2 feedback shows while Shift is held | Play, Rec and Loop follow REAPER's transport. Browse is lit while one of the selected track's plugin windows is open. Instance shows the view: off in Mix, medium in Track, full in Komplete Kontrol. While Shift is held, Rec shows the metronome and Loop shows auto-punch. Other buttons glow dimly and light fully while held |
| Left display | *MIDI* and the channel in use (*CH 1*, or *CH 2* while Shift is held) | *MIX* with the tracks on the knobs, the track with *TRK n* and its page, or *KOMPLETE KONTROL* in the Komplete Kontrol view |
| Knob displays | Each knob's CC, its value and a bar; the Shift layer's while Shift is held | Track names, values and bars, as in each view above. Touching a knob frames its bar and leaves the other displays as they are |
| Short messages | — | *PANIC*, *SAVE*, *RENDER*, *SCREEN SET n* with the screenset's name on the third display, *FX 2/3* with the plugin's name, and the new record mode. Until REAPER answers: *waiting for OSC from REAPER* |

The keyboard blanks its own displays when Preset ▲ / ▼ is pressed, so the bridge redraws them 50 ms after every button press or release.

## Changing assignments

Everything in native mode can be changed with **PrimoKKMK1Bridge Editor** (`editor/build.sh`, then open
`build/PrimoKKMK1Editor.app`), or directly in `bridge/PrimoKKMK1Bridge.json`. A running bridge applies a saved
change by itself within a second or two. `build/PrimoKKMK1Bridge --print-default-config` prints every default.

| To change | Config key |
| --- | --- |
| A button's CC, or silence it | `buttons` (button name → CC, or `null`) |
| Channels | `channel` (default 1), `shiftChannel` (default 2, or `null` to make Shift a plain button) |
| Knob CCs and their mode | `knobCCs`, `knobMode` (`absolute` or one of three relative modes), `knobStepsPerCC` |
| Touch CCs | `knobTouchCCs`, `navigateTouchCC` |
| Navigate knob turn | `navigateTurnCC`, `navigateTurnMode` |
| REAPER commands | `reaper.buttons` and `reaper.shiftButtons` (button name → command, `action:<ID>` for any REAPER action, or `null` for the button's CC) |
| What the Navigate knob scrolls in REAPER mode | `reaper.navigateTurn`: `tracks`, `pages`, or `null` for its CC |
| The view at start | `reaper.view`: `mix`, `track` or `komplete-kontrol` |
| Komplete Kontrol CCs | `reaper.kompleteKontrol`: `channel`, `encoderCCs`, `encoderMode`, `buttons` |

The full list of keys is in [bridge/README.md](../bridge/README.md#configuration) under *Configuration*.
