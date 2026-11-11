--
--  PrimoKKMK1Bridge_TrackColor.lua
--  PrimoKKMK1Bridge
--
--  Created by George Senger on 11/11/2026.
--  Copyright © 2026 Primo Studios. All rights reserved.
--
--  Licensed under the MIT License. See LICENSE in the project root or
--  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
--
--  Runs inside REAPER and sends the selected track's colour to PrimoKKMK1Bridge, which shows it on the keyboard's
--  light guide (REAPER's OSC doesn't report track colours). It sends SysEx to the bridge's MIDI output,
--  "Primo Komplete Kontrol MK1", when the selected track or its colour changes, and every 2 seconds so a bridge
--  that has restarted catches up:
--    F0 7D 50 4B 01 rr gg bb F7   the colour, 0-127 each
--    F0 7D 50 4B 02 F7            no colour: the track has none, or no track is selected
--  When the script stops (or REAPER quits), it sends "no colour", so the keys go dark.
--
--  Setup, once: enable the "Primo Komplete Kontrol MK1" MIDI output in REAPER's preferences, and run this script
--  at startup. See "Track colour on the keys" in doc/GUIDE.md.

local PORT = "Primo Komplete Kontrol MK1"
local RESEND = 2  -- seconds between repeats, and between looks for the port
local NO_COLOUR = string.char(0xF0, 0x7D, 0x50, 0x4B, 0x02, 0xF7)

local output, lastLook = nil, -1e9
local lastMessage, lastSent = nil, -1e9

-- The bridge's MIDI output, by name. Looked up again regularly: its index can change when the bridge restarts.
local function findOutput()
  for i = 0, reaper.GetNumMIDIOutputs() - 1 do
    local ok, name = reaper.GetMIDIOutputName(i, "")
    if ok and name == PORT then return i end
  end
  return nil
end

local function colourMessage()
  local track = reaper.GetSelectedTrack(0, 0)
  local native = track and reaper.GetTrackColor(track) or 0
  if native & 0x1000000 == 0 then return NO_COLOUR end  -- no custom colour
  local r, g, b = reaper.ColorFromNative(native & 0xFFFFFF)
  return string.char(0xF0, 0x7D, 0x50, 0x4B, 0x01, r >> 1, g >> 1, b >> 1, 0xF7)
end

local function loop()
  local now = reaper.time_precise()
  if now - lastLook > RESEND then
    local found = findOutput()
    if found ~= output then lastMessage = nil end  -- a new port: send at once
    output, lastLook = found, now
  end
  local message = colourMessage()
  if output and (message ~= lastMessage or now - lastSent > RESEND) then
    reaper.SendMIDIMessageToHardware(output, message)
    lastMessage, lastSent = message, now
  end
  reaper.defer(loop)
end

reaper.atexit(function()
  if output then reaper.SendMIDIMessageToHardware(output, NO_COLOUR) end
end)

loop()
