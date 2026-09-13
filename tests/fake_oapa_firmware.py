#!/usr/bin/env python3
"""Fake OAPA controller on a pseudo-terminal, mirroring reference firmware 1.2.2.

Used to test the INDI driver without hardware. Behaviour copied from
oapa-firmware oapa.ino 1.2.2:
  - "?"  -> status frame, then "ok"  (exactly two lines)
  - "$J=G91G21X<n>Y<n>F<f>" relative jog in steps, F = steps/s clamped 50-3000,
    absent -> 2000; "$J=G53..." absolute
  - "X<n>" / "Y<n>" direct relative move at the default speed
  - "!"  -> stop both axes, positions stay true, "ok"
  - anything else -> "ok"
Motion is time based (constant speed, no ramp). A boot banner is printed at start.

Options let a test provoke the failure paths the driver must catch:
  --version  report another firmware version ("" = no V: field)
  --stall    report Run forever without the position ever changing
  --ignore-stop  acknowledge "!" but keep moving (pre-1.2.1 firmware)

Every received command is echoed to stdout as "CMD <line>" and every completed
state change as "POS x y", so a test can assert on what reached the wire.
"""
import argparse
import os
import pty
import select
import sys
import time
import tty

DEFAULT_SPEED = 2000.0
SPEED_MIN, SPEED_MAX = 50.0, 3000.0


class Axis:
    def __init__(self):
        self.position = 0.0
        self.target = 0.0
        self.speed = DEFAULT_SPEED

    def advance(self, dt):
        step = self.speed * dt
        delta = self.target - self.position
        if abs(delta) <= step:
            self.position = self.target
        else:
            self.position += step if delta > 0 else -step

    def running(self):
        return round(self.position) != round(self.target)


def axis_value(spec, letter):
    at = spec.find(letter)
    if at < 0:
        return None
    end = at + 1
    while end < len(spec) and (spec[end].isdigit() or spec[end] in ".-"):
        end += 1
    try:
        return float(spec[at + 1:end])
    except ValueError:
        return 0.0


class Firmware:
    def __init__(self, version, stall, ignore_stop):
        self.axes = {"X": Axis(), "Y": Axis()}
        self.version = version
        self.stall = stall
        self.ignore_stop = ignore_stop
        self.stalled_running = False
        self.config = {}

    def advance(self, dt):
        if self.stall:
            return
        for axis in self.axes.values():
            axis.advance(dt)

    def status_frame(self):
        running = self.stalled_running or any(a.running() for a in self.axes.values())
        x, y = (round(self.axes[k].position) for k in ("X", "Y"))
        frame = f"<{'Run' if running else 'Idle'}|MPos:{x:.2f},{y:.2f},0.00"
        if self.version:
            frame += f"|V:{self.version}"
        return frame + "|>"

    def handle(self, line):
        line = line.strip()
        if not line:
            return []
        print(f"CMD {line}", flush=True)
        if line[0] == "?":
            return [self.status_frame(), "ok"]
        if line[0] == "!":
            if not self.ignore_stop:
                self.stalled_running = False
                for axis in self.axes.values():
                    axis.target = axis.position
            return ["ok"]
        if line.startswith("$J="):
            spec = line[3:]
            relative, absolute = "G91" in spec, "G53" in spec
            if relative or absolute:
                feed = axis_value(spec, "F")
                speed = DEFAULT_SPEED if not feed or feed <= 0 else min(max(feed, SPEED_MIN), SPEED_MAX)
                for letter, axis in self.axes.items():
                    value = axis_value(spec, letter)
                    if value is None:
                        continue
                    axis.speed = speed
                    axis.target = (axis.target if relative else 0) + round(value)
                    if self.stall and value:
                        self.stalled_running = True
            return ["ok"]
        if line[0] in "XYxy" and len(line) > 1 and (line[1].isdigit() or line[1] == "-"):
            axis = self.axes[line[0].upper()]
            axis.speed = DEFAULT_SPEED
            axis.target += int(line[1:])
            return ["ok"]
        if len(line) > 2 and line[0].upper() in "CHS":
            # Type-first driver configuration (CX600, HY25, SX16). Any other shape, such as
            # the axis-first "XC600", falls through to a plain "ok" and is ignored, exactly
            # like the firmware. A non-axis second letter falls back to Y, as there.
            axis = line[1].upper() if line[1].upper() in "XY" else "Y"
            try:
                value = int(line[2:])
            except ValueError:
                value = 0
            self.config[line[0].upper() + axis] = value
            print(f"CFG {line[0].upper()}{axis}={value}", flush=True)
            return ["ok"]
        return ["ok"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--link", required=True, help="symlink path to create for the pty, e.g. /tmp/ttyOAPA")
    parser.add_argument("--version", default="1.2.2")
    parser.add_argument("--stall", action="store_true")
    parser.add_argument("--ignore-stop", action="store_true")
    args = parser.parse_args()

    master, slave = pty.openpty()
    tty.setraw(master)
    if os.path.lexists(args.link):
        os.remove(args.link)
    os.symlink(os.ttyname(slave), args.link)

    fw = Firmware(args.version, args.stall, args.ignore_stop)
    os.write(master, b"\r\n--- OAPA controller ready ---\r\nfirmware fake | Waiting for commands...\r\n")
    print(f"READY {args.link}", flush=True)

    buffer = b""
    last = time.monotonic()
    last_pos = None
    try:
        while True:
            readable, _, _ = select.select([master], [], [], 0.02)
            now = time.monotonic()
            fw.advance(now - last)
            last = now

            pos = tuple(round(a.position) for a in fw.axes.values())
            if pos != last_pos and not any(a.running() for a in fw.axes.values()):
                print(f"POS {pos[0]} {pos[1]}", flush=True)
                last_pos = pos

            if not readable:
                continue
            try:
                chunk = os.read(master, 1024)
            except OSError:
                continue
            buffer += chunk
            while b"\n" in buffer or b"\r" in buffer:
                cut = min(i for i in (buffer.find(b"\n"), buffer.find(b"\r")) if i >= 0)
                line, buffer = buffer[:cut], buffer[cut + 1:]
                for reply in fw.handle(line.decode(errors="replace")):
                    os.write(master, reply.encode() + b"\r\n")
    except KeyboardInterrupt:
        pass
    finally:
        if os.path.lexists(args.link):
            os.remove(args.link)


if __name__ == "__main__":
    sys.exit(main())
