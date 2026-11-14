# PrimoKKMK1Bridge

Custom Native Instruments Komplete Kontrol S-series MK1 (S25/S49/S61/S88) MIDI controller driver for macOS; bringing complete configurability (every button, knob and touch), basic NKS support and Reaper DAW integration to the no longer supported MIDI controller. PrimoKKMK1Bridge replaces the need for the Native Instruments drivers (NIHardwareAgent, NIHostIntegrationAgent) and Controller Editor.

The system consists of two programs:

- **The bridge** (`PrimoKKMK1Bridge`) talks to the keyboard and runs in the background - replaces the proprietary Native Instruments drivers.
- **The editor** (*PrimoKKMK1Editor*) is a Mac app for changing the assignments and settings of the keyboard, and for starting and stopping the bridge - replaces the Native Instruments Controller Editor.

> *PrimoKKMK1Editor* contains an embedded `PrimoKKMK1Bridge` so there is no need to install anything else.

**Using it:** the [user guide](https://gsenger3.github.io/PrimoKKMK1Bridge/) covers installing, setup, starting at
login, every mode and view, every default assignment, and the config file. The editor's Help menu opens it. Its
source is [doc/GUIDE.md](doc/GUIDE.md).

Tested on an S61 MK1 (firmware 72) with macOS 26 and REAPER 7.61.

## How It Works

On connect, the bridge sends the keyboard the same 3-byte HID "init" (`a0 00 00`) that NI's software and
DrivenByMoss send. That switches it from MIDI mode to native mode, where every button, knob touch and knob turn
is reported over USB HID, and the computer drives the lights and displays. The bridge turns those reports into
MIDI CCs, or in REAPER mode into OSC messages to REAPER. The keys and strips keep coming from the keyboard's own
MIDI port, and are merged into the bridge's port too. The protocol details are in [doc/NOTES.md](doc/NOTES.md).

## What's Where

| Where | What |
| --- | --- |
| [bridge/Sources/](bridge/Sources/) | The bridge, one file per area: `main.swift` (command line, startup, restarts), `Bridge*.swift` (the keyboard's reports, lights, displays, REAPER mode, light guide, NKS pages), `NKS*.swift` (reading and learning Komplete Kontrol's NKS pages), `LearnedPages.swift` (the learned pages file, shared with the editor), `MIDIPorts.swift`, `OSC.swift`, `Reaper*.swift`, `Config.swift` (every config key, its default and validation) |
| [editor/Sources/](editor/Sources/) | The editor: the keyboard drawing, the inspector, the Settings page and its list of learned NKS pages, the bridge switch, launching the bridge at login, and the REAPER script installer |
| [reaper/](reaper/PrimoKKMK1Bridge_TrackColor.lua) | A script for REAPER that sends the bridge the selected track's colour, for the light guide, and which instrument Komplete Kontrol hosts, for NKS pages |
| [doc/](doc/GUIDE.md) | The user guide (`GUIDE.md`) and its pictures, the user guide website's theme overrides and stylesheet (`site/`), the keyboard's protocol notes (`NOTES.md`), and which HID bit each button sets (`BUTTON_MAP.md`) |
| [design/](design/nks.md) | The spec for the Komplete Kontrol view |
| [tools/](tools/) | HID and MIDI monitors, the capture tool, `midisend`, a stand-in REAPER for testing, and the scripts that stamp the version and draw the guide's pictures |
| [device/](device/) | Raw captures and recorded test runs |

## Build and Run

**You need:**
- macOS 14 or later
- Xcode, or Apple's Command Line Tools (`xcode-select --install`). Tested with Xcode 27 (Swift 6.4).

Run the commands from the repository's top folder. Everything is built into `build/`, which git ignores.

### The Editor App, With the Bridge Inside It

```bash
editor/build.sh
```

```bash
open build/PrimoKKMK1Editor.app
```

`editor/build.sh` builds `build/PrimoKKMK1Editor.app`: the editor, its own copy of the bridge, the REAPER script,
and the app icon. It's signed for this Mac only (ad hoc), not notarized. In the editor, turn on the bridge switch
in the toolbar: the bridge then runs in the background and keeps running after you quit the editor. Saved
changes apply to a running bridge within a second or two.

After pulling changes, run `editor/build.sh` again. A running bridge isn't disturbed: turn it off and on in the
editor to run the new copy.

The app is built for compiling Mac's architecture. `editor/build.sh --arch universal` builds for the specified architecture (Apple Silicon and Intel), at about twice the size; `--arch arm64` or `--arch x86_64` picks one. Whatever the architecture, the editor and the bridge require macOS 14 or later.

### The Bridge On Its Own, In Terminal

```bash
bridge/build.sh
```

```bash
build/PrimoKKMK1Bridge --verbose
```

`bridge/build.sh` builds `build/PrimoKKMK1Bridge`; `editor/build.sh` doesn't, so run both after a bridge change if
you use this copy (for the replay tests below, say). `--verbose` prints every message the bridge sends; Ctrl-C
quits. Run one bridge at a time: the editor's switch also stops a bridge started this way.

Other options: `--config FILE` runs with another config file, `--print-default-config` prints every default,
`--log-osc` also prints what REAPER sends, and `--version` prints the version.

### After building

- **Config file:** `~/Library/Application Support/PrimoStudios/PrimoKKMK1Bridge/PrimoKKMK1Bridge.json`. The
  bridge or the editor creates it with every default the first time; a new config starts in MIDI mode.
- **REAPER:** turn REAPER mode on in the editor's Settings page, and set up REAPER's OSC device as described in
  [Set up REAPER](doc/GUIDE.md#set-up-reaper-once).
- **The guide's pictures** are drawn from the editor's own drawing: run `tools/render_guide_images.sh` after
  changing a default or the drawing.

### The User Guide

[The user guide](https://gsenger3.github.io/PrimoKKMK1Bridge/) is also a website, made with
[MkDocs](https://www.mkdocs.org) and its built-in theme from `doc/GUIDE.md` (see `mkdocs.yml` and `doc/site/`), and served by GitHub
Pages from the `gh-pages` branch. After changing the guide, preview the site, then publish it:

```bash
tools/build_site.sh serve
```

```bash
tools/build_site.sh deploy
```

The preview is at http://127.0.0.1:8000/PrimoKKMK1Bridge/. `deploy` builds the site and pushes it to `gh-pages`. The
first run installs MkDocs into `build/mkdocs-venv`, at the versions in `tools/site_requirements.txt`.

### Building a Release

```bash
tools/make_release.sh
```

It builds the two downloads for a GitHub release from the committed code (HEAD), with one version stamp, in
`build/release/`:

- `PrimoKKMK1Editor-<version>-macOS-arm64.zip`: Apple Silicon only, the smaller download.
- `PrimoKKMK1Editor-<version>-macOS-universal.zip`: Apple Silicon and Intel Macs.

It then checks each zip's architectures, minimum macOS and signature, and prints its size and SHA-256 for the
release notes. It doesn't publish anything. It stops if there are uncommitted changes, since they wouldn't be in the
release (`--allow-dirty` builds HEAD anyway), and `--ref TAG` rebuilds an earlier release.

## Versions

Both apps carry a version of the form **Major.minor (Build ID)**, such as `1.1 (20261112.0024)`:

- **Major.minor** comes from the [VERSION](VERSION) file. Edit it to release a new version.
- **Build ID** is the date and time of the build (YYYYMMDD.HHMM). Both build scripts stamp a new one on every
  build, using `tools/stamp_version.sh`, so building with a bare `swiftc` command doesn't work.
- **Where to see it:** the editor's **About PrimoKKMK1Bridge Editor**, `build/PrimoKKMK1Bridge --version`, and the
  first line the bridge prints when it starts.

## Testing Without the Keyboard

`--replay` runs a capture log (from `tools/kkmap`) through the bridge and prints what it would send, and the
displays' contents as text. Without `--config`, a replay uses the defaults and doesn't touch your config file.

```bash
build/PrimoKKMK1Bridge --replay device/tests/native_knobs_results/capture_mapping.log
```

For REAPER mode, start the stand-in REAPER first, then replay with a config that points at it:

```bash
python3 tools/fake_reaper.py --listen 18000 --send 19000 --seconds 8 &
```

```bash
build/PrimoKKMK1Bridge --replay device/tests/reaper_sim/synthetic_reaper_test.log --config device/tests/reaper_sim/reaper_test_config.json
```

- The recorded REAPER tests are `device/tests/reaper_sim/*_test.log`, each with the output it gave in
  `*_replay.log`. Replaying them through two builds and comparing the output shows what a change did.
- `reaper_test_config.json` keeps the REAPER button assignments the older tests were made with, from before
  issues #11, #12 and #13 changed the defaults. A test with its own `<name>_config.json` uses that instead:
  `reaper_defaults_test` checks the current defaults.
- `build/PrimoKKMK1Bridge --show-font` draws every character the displays can show.
- `tools/midisend.swift` sends CCs to the bridge's MIDI output, to try DAW feedback without a DAW. Build it with
  `swiftc -O tools/midisend.swift -o build/midisend`; then `build/midisend "Primo Komplete Kontrol MK1" 1 102 127`
  lights Play, and `... 1 102 0` dims it.

Not affiliated with Native Instruments; Komplete Kontrol is their trademark. NI's firmware isn't included.

[MIT License](LICENSE)
