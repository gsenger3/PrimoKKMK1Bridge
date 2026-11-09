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

## Build and run

**You need:**
- macOS 14 or later
- Xcode, or Apple's Command Line Tools (`xcode-select --install`). Tested with Xcode 27 (Swift 6.4).

Run the commands from the repository's top folder. Everything is built into `build/`, which git ignores.

### The editor app (includes the bridge)

The usual way. `editor/build.sh` builds `build/PrimoKKMK1Editor.app`: the editor, a copy of the bridge inside
it, and the app icon.

```bash
editor/build.sh
```

```bash
open build/PrimoKKMK1Editor.app
```

In the editor, turn on the bridge switch in the toolbar. The bridge runs in the background with
`bridge/PrimoKKMK1Bridge.json` and keeps running after you quit the editor. Whatever you save in the editor
applies to the running bridge within a second or two.

### The bridge on its own, in Terminal

```bash
mkdir -p build && swiftc -O bridge/Sources/*.swift -o build/PrimoKKMK1Bridge
```

```bash
build/PrimoKKMK1Bridge --config bridge/PrimoKKMK1Bridge.json --verbose
```

`--verbose` prints every message the bridge sends; Ctrl-C quits. Run one bridge at a time: the editor's switch
also stops a bridge started this way.

### After building

- **REAPER:** set up its OSC device and enable **Primo Komplete Kontrol MK1** as a MIDI input, as described in
  [Set up REAPER](bridge/README.md#set-up-reaper-once).
- **Plain MIDI CCs:** the included config has REAPER mode on. Switch it off on the editor's Settings page.
- **Updates:** after pulling changes, run `editor/build.sh` again. It doesn't disturb a running bridge; turn the
  bridge off and on in the editor to run the new copy.

See [bridge/README.md](bridge/README.md) for everything else.

Not affiliated with Native Instruments; Komplete Kontrol is their trademark. NI's firmware isn't included.

[MIT License](LICENSE)
