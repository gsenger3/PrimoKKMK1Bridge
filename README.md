# PrimoKKMK1Bridge

Makes a Native Instruments Komplete Kontrol S-series MK1 keyboard (S25/S49/S61/S88) fully usable on macOS
without NI's software. Every button, knob and touch becomes MIDI on a virtual port, **Primo Komplete Kontrol
MK1**, the button lights and the nine displays are driven too, and an optional REAPER mode turns the keyboard
into a control surface over OSC, with Mix, Track and Komplete Kontrol views.

Tested on an S61 MK1 (firmware 72) with macOS 26 and REAPER 7.61.

| Where | What |
| --- | --- |
| [bridge/](bridge/README.md) | The bridge: its Swift sources, config, and how to build, run and set up REAPER |
| [editor/](bridge/README.md#editor) | PrimoKKMK1Bridge Editor, a Mac app for changing the assignments on a drawing of the keyboard |
| [doc/CONTROLS.md](doc/CONTROLS.md) | Every control's job and CC in every mode |
| [doc/NOTES.md](doc/NOTES.md) | The keyboard's USB HID protocol, as worked out here |
| [doc/BUTTON_MAP.md](doc/BUTTON_MAP.md) | Which HID bit each button sets |
| [design/](design/nks.md) | The spec for the Komplete Kontrol view |
| [tools/](tools/) | HID and MIDI monitors, the capture tool, and a stand-in REAPER for testing |
| [device/](device/) | Raw captures and test results |

## Quick start

```bash
mkdir -p build && swiftc -O bridge/Sources/*.swift -o build/PrimoKKMK1Bridge
```

```bash
build/PrimoKKMK1Bridge --config bridge/PrimoKKMK1Bridge.json --verbose
```

To change assignments, build and open the editor; a running bridge applies what you save:

```bash
editor/build.sh && open build/PrimoKKMK1Editor.app
```

The included config has REAPER mode on; switch it off on the editor's Settings page for plain MIDI CCs. See
[bridge/README.md](bridge/README.md) for everything else.

Not affiliated with Native Instruments; Komplete Kontrol is their trademark. NI's firmware isn't included.

[MIT License](LICENSE)
