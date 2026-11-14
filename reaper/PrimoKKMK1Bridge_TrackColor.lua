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
--  Runs inside REAPER and tells PrimoKKMK1Bridge two things REAPER's OSC doesn't report: the selected track's colour,
--  which the bridge shows on the keyboard's light guide, and which instrument the selected track's Komplete Kontrol
--  plugin hosts, for the Komplete Kontrol view's NKS pages (NKS integration). It sends SysEx to the bridge's MIDI
--  output, "Primo Komplete Kontrol MK1", when either changes, and every 2 seconds so a bridge that has restarted
--  catches up:
--    F0 7D 50 4B 01 rr gg bb F7   the colour, 0-127 each
--    F0 7D 50 4B 02 F7            no colour: the track has none, or no track is selected
--    F0 7D 50 4B 03 <id> F7       the instrument Komplete Kontrol hosts, from KK's saved state, in ASCII: its
--                                 format and ID, e.g. "VST3:41727475415649534D6E465650726F63" (MiniFreak V)
--    F0 7D 50 4B 04 F7            no instrument: the selected track's instrument isn't Komplete Kontrol
--    F0 7D 50 4B 05 <hex> F7      after 03: the fingerprint of the hosted instrument's parameter names, 8 hex digits
--                                 in ASCII. It tells Kontakt's instruments apart (they share Kontakt's ID), so each
--                                 has its own learned NKS pages.
--  When the script stops (or REAPER quits), it sends "no colour" and "no instrument", so the keys go dark.
--
--  Setup, once: enable the "Primo Komplete Kontrol MK1" MIDI output in REAPER's preferences, and run this script
--  at startup. See "Track colour on the keys" in doc/GUIDE.md.

local PORT = "Primo Komplete Kontrol MK1"
local RESEND = 2  -- seconds between repeats, and between looks for the port
local NO_COLOUR = string.char(0xF0, 0x7D, 0x50, 0x4B, 0x02, 0xF7)
local NO_INSTRUMENT = string.char(0xF0, 0x7D, 0x50, 0x4B, 0x04, 0xF7)

local output, lastLook = nil, -1e9
local sent = {}  -- kind ("colour", "instrument") -> the message last sent, and when
local instrumentMessage, instrumentCheck = NO_INSTRUMENT, nil
local fingerprintMessage, fingerprintTime = nil, -1e9

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

local BASE64 = {}
for i, c in ipairs({ ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"):byte(1, -1) }) do
  BASE64[c] = i - 1
end

-- Decode base64. "=" ends a run (REAPER's chunks can be several runs back to back); other characters are skipped.
local function fromBase64(s)
  local out, bits, n = {}, 0, 0
  for i = 1, #s do
    local c = s:byte(i)
    local v = BASE64[c]
    if c == 61 then
      bits, n = 0, 0
    elseif v then
      bits, n = (bits << 6) | v, n + 6
      if n >= 8 then
        n = n - 8
        out[#out + 1] = string.char((bits >> n) & 0xFF)
        bits = bits & ((1 << n) - 1)
      end
    end
  end
  return table.concat(out)
end

-- The instrument Komplete Kontrol hosts on `track`, as "<format>:<hex ID>"; nil if the track's instrument isn't
-- Komplete Kontrol. KK's saved state names it near the start, e.g. "Arturia:VST3:INSTR:41727475…".
local function kkInstrument(track)
  local fx = track and reaper.TrackFX_GetInstrument(track) or -1
  if fx < 0 then return nil end
  local ok, name = reaper.TrackFX_GetNamedConfigParm(track, fx, "original_name")
  if not ok then _, name = reaper.TrackFX_GetFXName(track, fx, "") end
  if not name:find("Komplete Kontrol", 1, true) then return nil end
  local got, chunk = reaper.TrackFX_GetNamedConfigParm(track, fx, "vst_chunk")
  if not got then return nil end
  local format, id = fromBase64(chunk:sub(1, 4096)):match("(%w+):INSTR:(%x+)")
  return format and (format .. ":" .. id) or nil
end

-- Reading KK's saved state makes the plugin save it, so it's read again only when something cheap to check changes:
-- the selected track, its instrument, or the hosted instrument's parameter count or first parameter name (KK's 101).
local function instrumentCheckValue(track)
  local fx = track and reaper.TrackFX_GetInstrument(track) or -1
  if fx < 0 then return tostring(track) end
  local _, first = reaper.TrackFX_GetParamName(track, fx, 101, "")
  return table.concat({ tostring(track), fx, reaper.TrackFX_GetNumParams(track, fx), first }, "|")
end

-- The fingerprint of the instrument's parameter names (KK's parameters from 101 on, "107 Balance"), without their
-- numbers, and leaving out Kontakt's unassigned ones ("165 #064"): 32-bit FNV-1a, as 8 hex digits.
local function kkFingerprint(track, fx)
  local h = 2166136261
  for i = 101, reaper.TrackFX_GetNumParams(track, fx) - 1 do
    local _, name = reaper.TrackFX_GetParamName(track, fx, i, "")
    name = name:gsub("^%d+ ", "", 1)
    if not name:match("^#%d+$") then
      for j = 1, #name do h = ((h ~ name:byte(j)) * 16777619) & 0xFFFFFFFF end
      h = ((h ~ 10) * 16777619) & 0xFFFFFFFF  -- a newline between names
    end
  end
  return string.format("%08X", h)
end

-- The instrument message, and the fingerprint message (nil without a KK instrument). The fingerprint is worked out
-- again when the instrument changes, and every RESEND seconds: two Kontakt instruments can share the parameter
-- count and first name that the check looks at.
local function instrument(now)
  local track = reaper.GetSelectedTrack(0, 0)
  local check = instrumentCheckValue(track)
  local changed = check ~= instrumentCheck
  if changed then
    local id = kkInstrument(track)
    instrumentMessage = id and (string.char(0xF0, 0x7D, 0x50, 0x4B, 0x03) .. id .. string.char(0xF7)) or NO_INSTRUMENT
    instrumentCheck = check
  end
  if instrumentMessage == NO_INSTRUMENT then
    fingerprintMessage = nil
  elseif changed or now - fingerprintTime > RESEND then
    local fp = kkFingerprint(track, reaper.TrackFX_GetInstrument(track))
    fingerprintMessage = string.char(0xF0, 0x7D, 0x50, 0x4B, 0x05) .. fp .. string.char(0xF7)
    fingerprintTime = now
  end
  return instrumentMessage, fingerprintMessage
end

-- Send a message of a kind when it changes, and again every RESEND seconds.
local function send(kind, message, now)
  local last = sent[kind]
  if last and last.message == message and now - last.time <= RESEND then return end
  reaper.SendMIDIMessageToHardware(output, message)
  sent[kind] = { message = message, time = now }
end

local function loop()
  local now = reaper.time_precise()
  if now - lastLook > RESEND then
    local found = findOutput()
    if found ~= output then sent = {} end  -- a new port: send at once
    output, lastLook = found, now
  end
  if output then
    send("colour", colourMessage(), now)
    local inst, fingerprint = instrument(now)
    if not sent.instrument or sent.instrument.message ~= inst then sent.fingerprint = nil end  -- it follows a new 03
    send("instrument", inst, now)
    if fingerprint then send("fingerprint", fingerprint, now) end
  end
  reaper.defer(loop)
end

reaper.atexit(function()
  if output then
    reaper.SendMIDIMessageToHardware(output, NO_COLOUR)
    reaper.SendMIDIMessageToHardware(output, NO_INSTRUMENT)
  end
end)

loop()
