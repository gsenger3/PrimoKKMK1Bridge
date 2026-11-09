# Implement Komplete Kontrol Integration View

Implement an additional view for Reaper/Native mode to support Native Instruments Komplete Kontrol integration via NKS. This view should support the NKS standard similar to how the Novation Launchkey MK4 does.

## Encoder Mappings

- Encoder 1: MIDI CC 21
- Encoder 2: MIDI CC 22
- Encoder 3: MIDI CC 23
- Encoder 4: MIDI CC 24
- Encoder 5: MIDI CC 25
- Encoder 6: MIDI CC 26
- Encoder 7: MIDI CC 27
- Encoder 8: MIDI CC 28

## Button Mappings

- Preset Up: MIDI CC 37
- Preset Down: MIDI CC 36
- Up Button: MIDI CC 41
- Down Button: MIDI CC 40
- Left Button: MIDI CC 42
- Right Button: MIDI CC 43

Existing button assignments not defined above should retain their current assignments. The `Instance` button should be updated to scroll through all 3 views: `Mix` (Default), `Track`, `Komplete Kontrol`. Change the `Instance` button to a color when in Komplete Kontrol mode.