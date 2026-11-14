#!/usr/bin/env python3
"""fake_reaper: a stand-in for REAPER's OSC control surface, for testing PrimoKKMK1Bridge without REAPER.

    python3 tools/fake_reaper.py [--listen 8000] [--send 9000] [--seconds 10]

It listens where REAPER would (REAPER's "local listen port"), answers like REAPER's Default.ReaperOSC
patterns for a made-up 11-track project (the first track has 6 sends, track 3 has no name), and prints
every message it receives. Like REAPER, it only sends a value when it differs from what it last sent to
that address, until it gets /action 41743 ("Control surface: Refresh all surfaces"), and it fills unused
track and send slots with REAPER's stand-ins ("Track 12", "Send 3" at -inf dB). Point PrimoKKMK1Bridge's
reaper.sendPort/receivePort at it.
"""
import argparse
import math
import socket
import struct
import time


def osc_string(s):
    b = s.encode() + b"\0"
    return b + b"\0" * (-len(b) % 4)


def message(address, *args):
    tags, data = ",", b""
    for a in args:
        if isinstance(a, float):
            tags, data = tags + "f", data + struct.pack(">f", a)
        elif isinstance(a, int):
            tags, data = tags + "i", data + struct.pack(">i", a)
        else:
            tags, data = tags + "s", data + osc_string(a)
    return osc_string(address) + osc_string(tags) + data


def bundle(msgs):
    out = osc_string("#bundle") + struct.pack(">Q", 1)
    for m in msgs:
        out += struct.pack(">i", len(m)) + m
    return out


def read_string(d, i):
    end = d.index(b"\0", i)
    return d[i:end].decode(errors="replace"), (end + 4) & ~3


def parse(d):
    head, i = read_string(d, 0)
    if head == "#bundle":
        i += 8
        out = []
        while i + 4 <= len(d):
            (n,) = struct.unpack(">i", d[i:i + 4])
            out += parse(d[i + 4:i + 4 + n])
            i += 4 + n
        return out
    args = []
    if i < len(d) and d[i:i + 1] == b",":
        tags, i = read_string(d, i)
        for t in tags[1:]:
            if t == "f":
                args.append(round(struct.unpack(">f", d[i:i + 4])[0], 4)); i += 4
            elif t == "i":
                args.append(struct.unpack(">i", d[i:i + 4])[0]); i += 4
            elif t == "s":
                s, i = read_string(d, i); args.append(s)
    return [(head, args)]


def db(v):
    return "-inf dB" if v <= 0 else f"{40 * math.log10(v / 0.716):.2f}dB"


def pan_str(p):
    return "C" if abs(p - 0.5) < 0.005 else f"{abs(p - 0.5) * 200:.0f}%{'L' if p < 0.5 else 'R'}"


NAMES = ["Kick", "Snare", "", "Bass", "Keys", "Lead Vocal", "Backing Vocals", "Guitar", "Drum Bus",
         "Reverb", "Delay"]
SENDS = {0: ["Drum Bus", "Reverb", "Delay", "Parallel Comp", "Sidechain", "Room"], 1: ["Drum Bus", "Reverb"],
         5: ["Reverb", "Delay"]}
FX = {0: ["VST3: ReaEQ (Cockos)", "Komplete Kontrol (Native Instruments) (32 out)", "JS: Delay"], 2: ["VSTi: Massive X (Native Instruments)"]}
# The Komplete Kontrol plugin's host parameters, laid out like KK 3 does (as captured from REAPER 7.61): 1 "NIKB00",
# then KK's own "1 Scale On / Off" ... "100 -", then the loaded instrument's NKS parameters from "101 <name>" on.
NKS = [("Volume", "dB"), ("Tune", "Hz"), ("Unison", ""), ("Detune", "%"), ("Voice", ""), ("Glide", "ms"), ("LFO Mod", "%"),
       ("PWM Mod", "%"), ("Cutoff", "Hz"), ("Reso", "%"), ("Env Amount", "%"), ("LFO", "%"), ("Keyboard", "%"),
       ("Attack", "ms"), ("Decay", "ms"), ("Sustain", "%"), ("Release", "ms"), ("Chorus", ""), ("Delay", "%"), ("Reverb", "%")]


def kk_params():
    out = [["NIKB00", 0.0, ""]]
    own = {1: "Scale On / Off", 2: "Scale Root Note", 3: "Scale Type", 26: "Arp On / Off"}
    for n in range(1, 101):
        out.append([f"{n} {own.get(n, '-')}", 0.0, "Off" if n in own else ""])
    for i, (name, unit) in enumerate(NKS):
        out.append([f"{101 + i} {name}", 0.5, f"{50}{unit}" if unit else ""])  # some switches have no text, as in KK
    while len(out) < 256:
        out.append([f"{len(out)} -", 0.0, ""])
    return out


def kk_text(name, v):
    unit = dict(NKS).get(name.split(" ", 1)[1], "")
    return f"{round(v * 100)}{unit}" if unit else ""


class Reaper:
    def __init__(self, sock, dest):
        self.sock, self.dest = sock, dest
        self.tracks = [{"name": n, "vol": 0.716, "pan": 0.5, "mute": False, "solo": False, "recarm": False, "monitor": 0,
                        "sends": [[s, 0.5] for s in SENDS.get(i, [])],
                        "fx": [[f, 0.0] for f in FX.get(i, [])]} for i, n in enumerate(NAMES)]  # [name, window open]
        self.bank_start, self.device, self.track_count, self.send_count, self.fx_count = 0, 0, 8, 4, 8
        self.device_fx, self.param_count = 0, 8
        self.inst_count, self.inst_bank = 16, 1  # the instrument parameters reported (Default.ReaperOSC: 16)
        self.params = {}  # (track, fx) -> host parameters [name, value, text]
        self.playing = self.recording = self.repeating = self.click = False
        self.follow_last_touched = False
        self.cache = {}  # address -> last message sent there

    def send(self, msgs):
        fresh = []
        for m in msgs:
            address = m[:m.index(b"\0")]
            if self.cache.get(address) != m:
                self.cache[address] = m
                fresh.append(m)
        for i in range(0, len(fresh), 40):  # keep packets small, as REAPER does
            self.sock.sendto(bundle(fresh[i:i + 40]), self.dest)

    def transport(self):
        return [message("/play", float(self.playing)), message("/record", float(self.recording)),
                message("/repeat", float(self.repeating)), message("/click", float(self.click))]

    def strip(self, prefix, t):
        if t >= len(self.tracks):  # past the last track REAPER sends a stand-in, as captured from REAPER 7.61
            return [message(prefix + "/name", f"Track {t + 1}"), message(prefix + "/number/str", str(t + 1)),
                    message(prefix + "/volume", 0.00251387), message(prefix + "/volume/str", "-inf dB"),
                    message(prefix + "/volume/db", -150.0), message(prefix + "/pan", 0.5), message(prefix + "/pan/str", "C"),
                    message(prefix + "/pan2", 0.5), message(prefix + "/pan2/str", "0W"),
                    message(prefix + "/mute", 0.0), message(prefix + "/solo", 0.0)]
        tr = self.tracks[t]
        vol_db = -150.0 if tr["vol"] <= 0 else 40 * math.log10(tr["vol"] / 0.716)
        return [message(prefix + "/name", tr["name"] or f"Track {t + 1}"), message(prefix + "/number/str", str(t + 1)),
                message(prefix + "/volume", tr["vol"]), message(prefix + "/volume/str", db(tr["vol"])),
                message(prefix + "/volume/db", vol_db), message(prefix + "/pan", tr["pan"]),
                message(prefix + "/pan/str", pan_str(tr["pan"])), message(prefix + "/pan2", 1.0),
                message(prefix + "/pan2/str", "100W"),
                message(prefix + "/mute", float(tr["mute"])), message(prefix + "/solo", float(tr["solo"])),
                message(prefix + "/recarm", float(tr["recarm"])), message(prefix + "/monitor", float(tr["monitor"]))]

    def bank_state(self):
        out = []
        for n in range(1, self.track_count + 1):
            out += self.strip(f"/track/{n}", self.bank_start + n - 1)
        return out

    def device_state(self):
        out = self.strip("/track", self.device)
        sends = self.tracks[self.device]["sends"]
        for n in range(1, self.send_count + 1):
            if n <= len(sends):
                name, v = sends[n - 1]
                out += [message(f"/track/send/{n}/name", name), message(f"/track/send/{n}/volume", v),
                        message(f"/track/send/{n}/volume/str", db(v))]
            else:  # unused slot: a stand-in, as captured from REAPER 7.61
                out += [message(f"/track/send/{n}/name", f"Send {n}"), message(f"/track/send/{n}/volume", 0.00251387),
                        message(f"/track/send/{n}/volume/str", "-inf dB")]
        fx = self.tracks[self.device]["fx"]
        for n in range(1, self.fx_count + 1):  # empty slots: "" names, as captured from REAPER 7.61
            name, is_open = fx[n - 1] if n <= len(fx) else ("", 0.0)
            out += [message(f"/fx/{n}/name", name), message(f"/fx/{n}/number/str", str(n) if name else ""),
                    message(f"/fx/{n}/openui", is_open)]
        return out + self.param_state() + self.inst_state()

    def inst_fx(self):
        """The selected track's instrument: its first FX that is one (REAPER's /fxinst), or None."""
        fx = self.tracks[self.device]["fx"]
        return next((f for f, (name, _) in enumerate(fx) if name.startswith(("Komplete Kontrol", "VSTi:"))), None)

    def inst_state(self):
        """/fxinst/name and /fxinstparam/N/... for the run of instrument parameters asked for (count, bank)."""
        f = self.inst_fx()
        if f is None:
            return [message("/fxinst/name", "")]
        ps, out = self.fx_params(self.device, f), [message("/fxinst/name", self.tracks[self.device]["fx"][f][0])]
        for n in range(1, self.inst_count + 1):
            i = (self.inst_bank - 1) * self.inst_count + n
            name, v, text = ps[i - 1] if i <= len(ps) else ("", 0.0, "")
            out += [message(f"/fxinstparam/{n}/name", name), message(f"/fxinstparam/{n}/value", v),
                    message(f"/fxinstparam/{n}/value/str", text)]
        return out

    def fx_params(self, t, f):
        fx = self.tracks[t]["fx"]
        if f >= len(fx):
            return []
        if (t, f) not in self.params:
            self.params[(t, f)] = (kk_params() if fx[f][0].startswith("Komplete Kontrol")
                                   else [[f"Param {n}", 0.5, "50%"] for n in range(1, 33)])
        return self.params[(t, f)]

    def param_state(self):
        """/fxparam/N/... for the device FX (the one /device/fx/select picked) of the selected track."""
        ps, out = self.fx_params(self.device, self.device_fx), []
        for n in range(1, self.param_count + 1):
            name, v, text = ps[n - 1] if n <= len(ps) else ("", 0.0, "")
            out += [message(f"/fxparam/{n}/name", name), message(f"/fxparam/{n}/value", v), message(f"/fxparam/{n}/value/str", text)]
        return out

    def kk_move(self, slot, v):
        """Like turning a knob KK maps to NKS slot `slot`: the KK plugin's parameter changes and REAPER reports it."""
        ps = self.fx_params(0, 1)
        n = 102 + slot
        ps[n - 1][1], ps[n - 1][2] = v, kk_text(ps[n - 1][0], v)
        if self.device == 0 and self.device_fx == 1 and n <= self.param_count:
            self.send([message(f"/fxparam/{n}/value", v), message(f"/fxparam/{n}/value/str", ps[n - 1][2])])

    def changed(self, t):
        """Feedback after track t changed: its bank slot (if shown) and the selected track (if it is t)."""
        out = []
        if self.bank_start <= t < self.bank_start + self.track_count:
            out += self.strip(f"/track/{t - self.bank_start + 1}", t)
        if t == self.device:
            out += self.strip("/track", t)
        self.send(out)

    def handle(self, address, args):
        p = address.strip("/").split("/")
        dev = self.tracks[self.device]
        if address == "/device/track/follows/last_touched":
            self.follow_last_touched = True
        elif address == "/action" and args == [41743]:
            self.cache.clear()
            self.send(self.bank_state() + self.device_state() + self.transport())
        elif address == "/device/track/count":
            self.track_count = args[0]
            self.send(self.bank_state())
        elif address == "/device/send/count":
            self.send_count = args[0]
            self.send(self.device_state())
        elif address == "/device/fx/select":
            self.device_fx = args[0] - 1
            self.send(self.param_state())
        elif address == "/device/fxparam/count":
            self.param_count = args[0]
            self.send(self.param_state())
        elif address == "/device/fx/count":
            self.fx_count = args[0]
            self.send(self.device_state())
        elif address == "/device/fxinstparam/count":
            self.inst_count, self.inst_bank = args[0], 1
            self.send(self.inst_state())
        elif address == "/device/fxinstparam/bank/select":
            self.inst_bank = args[0]
            self.send(self.inst_state())
        elif p[0] == "fxinstparam" and p[2:] == ["value"] and self.inst_fx() is not None:
            ps = self.fx_params(self.device, self.inst_fx())
            i = (self.inst_bank - 1) * self.inst_count + int(p[1])
            if i <= len(ps):
                ps[i - 1][1], ps[i - 1][2] = args[0], kk_text(ps[i - 1][0], args[0])
                self.send([message(address, args[0]), message(address + "/str", ps[i - 1][2])])
        elif p[0] == "fx" and len(p) == 3 and p[2] == "openui":
            fx = self.tracks[self.device]["fx"]
            if int(p[1]) <= len(fx):
                fx[int(p[1]) - 1][1] = float(args[0] > 0.5)
                self.send([message(address, fx[int(p[1]) - 1][1])])
        elif address in ("/device/track/bank/+", "/device/track/bank/-"):
            step = self.track_count if address.endswith("+") else -self.track_count
            if 0 <= self.bank_start + step < len(self.tracks):
                self.bank_start += step
            self.send(self.bank_state())
        elif address in ("/device/track/+", "/device/track/-"):
            self.device = max(0, min(len(self.tracks) - 1, self.device + (1 if address.endswith("+") else -1)))
            self.send(self.device_state())
        elif p[0] == "track" and p[-2:] == ["volume", "db"]:  # /track/volume/db or /track/N/volume/db: set in dB
            t = self.bank_start + int(p[1]) - 1 if p[1].isdigit() else self.device
            if t < len(self.tracks):
                self.tracks[t]["vol"] = 0.716 * 10 ** (args[0] / 40)
                self.changed(t)
        elif p[0] == "track" and len(p) >= 2 and p[1].isdigit():
            t = self.bank_start + int(p[1]) - 1
            if t < len(self.tracks) and p[2:] in (["volume"], ["pan"]):
                self.tracks[t]["vol" if p[2] == "volume" else "pan"] = args[0]
                self.changed(t)
                if self.follow_last_touched and t != self.device:  # like REAPER: moving a fader touches that track
                    self.device = t
                    self.send(self.device_state())
        elif p[:2] == ["track", "send"] and p[3:] == ["volume"]:
            n = int(p[2]) - 1
            if n < len(dev["sends"]):
                dev["sends"][n][1] = args[0]
                self.send([message(address, args[0]), message(address + "/str", db(args[0]))])
        elif p[0] == "track" and p[1:] in (["volume"], ["pan"]):
            dev["vol" if p[1] == "volume" else "pan"] = args[0]
            self.changed(self.device)
        elif p[0] == "track" and p[1:] in (["recarm"], ["monitor"]):
            dev["recarm" if p[1] == "recarm" else "monitor"] = (args[0] > 0.5) if p[1] == "recarm" else int(round(args[0]))
            self.changed(self.device)
        elif p[0] == "track" and p[1] in ("mute", "solo"):
            dev[p[1]] = (not dev[p[1]]) if p[2:] == ["toggle"] else bool(args[0])
            self.changed(self.device)
        elif address == "/play":
            self.playing = True
            self.send([message("/play", 1.0)])
        elif address == "/stop":
            self.playing = self.recording = False
            self.send([message("/play", 0.0), message("/record", 0.0)])
        elif address == "/record":
            self.recording = not self.recording
            self.send([message("/record", float(self.recording))])
        elif address == "/click":
            self.click = not self.click
            self.send([message("/click", float(self.click))])
        elif address == "/repeat":
            self.repeating = not self.repeating
            self.send([message("/repeat", float(self.repeating))])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, default=8000)
    ap.add_argument("--send", type=int, default=9000)
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--kk-move-at", type=float, help="seconds in: move the KK plugin's NKS slot 9 (page 2, knob 2)")
    a = ap.parse_args()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", a.listen))
    sock.settimeout(0.1)
    r = Reaper(sock, ("127.0.0.1", a.send))
    print(f"fake REAPER: listening on {a.listen}, sending to {a.send}", flush=True)
    start = time.time()
    end = start + a.seconds
    moved = False
    while time.time() < end:
        if a.kk_move_at and not moved and time.time() - start >= a.kk_move_at:
            moved = True
            print("fake REAPER: moving KK NKS slot 9", flush=True)
            r.kk_move(9, 0.9)
        try:
            data, _ = sock.recvfrom(65536)
        except socket.timeout:
            continue
        for address, args in parse(data):
            print("fake REAPER got", address, *args, flush=True)
            r.handle(address, args)
    print("fake REAPER: done", flush=True)


if __name__ == "__main__":
    main()
