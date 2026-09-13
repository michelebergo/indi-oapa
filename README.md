# INDI OAPA — Open Automatic Polar Alignment

An [INDI](https://www.indilib.org/) driver for **OAPA** (Open Automatic Polar Alignment), a
motorised azimuth/altitude platform that corrects the polar alignment of an equatorial mount
without touching the knobs.

The driver implements the INDI **PAC (Polar Alignment Correction)** interface, the same one
used by the other polar-alignment correctors in INDI. The Ekos Polar Alignment Assistant can
therefore measure the error, command the correction and measure again, automatically.

> **Beta software.** Please report problems on the
> [issue tracker](https://github.com/michelebergo/indi-oapa/issues).

---

## Requirements

| Component | Details |
|-----------|---------|
| **INDI** | **2.2.0 or newer** (the PAC interface does not exist in older versions) |
| **KStars / Ekos** | **3.8.2 or newer** for automatic correction (marked preliminary in 3.8.2). Older versions can still drive the platform manually through the INDI Control Panel |
| **Controller** | ESP32 board (reference: FYSETC E4 + 2× TMC2209) |
| **Firmware** | [OAPA firmware](https://github.com/michelebergo/oapa-firmware) **1.2.1 or newer** (1.2.2 recommended) |
| **Connection** | USB serial, 115200 baud (`/dev/ttyUSB0` or `/dev/ttyACM0`) |

With firmware older than 1.2.1 the driver still connects, but speed and Abort are ignored
and a warning is logged.

---

## Installation

```bash
git clone https://github.com/michelebergo/indi-oapa.git
cd indi-oapa
sudo ./install.sh
```

The installer checks that your INDI has the PAC interface, builds the driver, and removes
the files of driver 1.x if present. To remove everything: `sudo ./uninstall.sh`.

---

## Setup in Ekos

1. **Profile Editor** → Auxiliary → select **OAPA**.
2. **INDI Control Panel** → OAPA → **Connection** tab: choose the serial port, click
   **Connect**. The board resets when the port opens; the driver waits for it.
3. Set **Calibration** for both axes (see below). Until you do, every correction is refused:
   the driver never guesses a gear ratio.
4. Do the **direction check** (see below) once.
5. In the Polar Alignment Assistant, enable automatic PAC correction and choose the success
   threshold.

| Control | Meaning |
|---------|---------|
| **Manual Adjustment** | Relative move in degrees. AZ positive = East, ALT positive = North |
| **Abort Motion** | Stops both axes |
| **Position** | Platform position in degrees since power-on |
| **Speed** | Motor speed per axis, 50–3000 steps/s (default 1000) |
| **Run Current** (Motor tab) | Motor run current per axis, mA (default 600) |
| **Hold Current** (Motor tab) | Hold current per axis, % of run current (default 25) |
| **Azimuth / Altitude Reverse** | Inverts an axis that moves the wrong way |
| **Calibration** | Motor steps per arcminute of correction, per axis |
| **Firmware** (Info tab) | Firmware version reported by the controller |

Run and hold current are sent to the controller on every connection, because it forgets them
at power-off. When the two axes have different speeds, a two-axis correction is sent as one
jog per axis.

---

## Calibration

The value is "motor steps per arcminute of correction". It depends on your mechanics:
typical values range from about 15 to about 1000.

Example for azimuth:

1. Set a rough value, e.g. `100`.
2. Run the Polar Alignment Assistant and note the azimuth error, e.g. `12.0'`.
3. Enter `0.1` (6 arcminutes) in the azimuth element of **Manual Adjustment**.
4. Refresh and note the new error, e.g. `8.0'`. The error changed by 4', not 6'.
5. New value = 100 × 6 / 4 = **150**.

Repeat for altitude.

## Direction check

Enter `+0.1` in the azimuth element of **Manual Adjustment**: the polar axis must move
**East**. Then `+0.1` in altitude: it must move **North** (up). If an axis moves the other
way, enable its **Reverse** switch.

---

## Testing without hardware

`tests/fake_oapa_firmware.py` emulates firmware 1.2.2 on a pseudo-terminal.
`tests/pac_contract_test.sh` starts it together with `indiserver` and drives
`PAC_MANUAL_ADJUSTMENT` the way Ekos does. It checks: driver currents sent on connection and on
change in the grammar the firmware accepts, calibration refusal, two-axis move and completion,
per-axis speed, reverse, rounding to whole steps, abort, stall detection, and old firmware.

```bash
tests/pac_contract_test.sh /path/to/indi_oapa
```

---

## Upgrading from driver 1.x or 2.0

Driver 3.0 is a rewrite on the PAC interface. Earlier versions never reached Ekos: they looked
for an INDI header that does not exist, so the automatic correction code was never built.

- The driver is now called **OAPA** (`indi_oapa`); re-select it in the Ekos profile.
- Kept, same names: `OAPA_SPEED` (`X_SPEED`, `Y_SPEED`), `OAPA_MOTOR_CURRENT` (`X_CURRENT`,
  `Y_CURRENT`), `OAPA_MOTOR_HOLD` (`X_HOLD`, `Y_HOLD`).
- **Check your motor currents after upgrading.** Driver 2.0 sent them as `XC600` / `XH50`,
  which the firmware acknowledges and ignores, so the motors always ran at the firmware
  defaults. Driver 3.0 sends `CX600` / `HX50`, so the values you set now take effect.
- Calibration is now in **steps per arcminute** (old steps per degree ÷ 60); gear ratio is
  folded into it.
- Replaced by standard PAC controls: `OAPA_JOG`, `OAPA_ABS_MOVE`, `OAPA_PAA_ERROR`,
  `OAPA_REVERSE_AZ`, `OAPA_REVERSE_ALT`.
- Removed: `OAPA_BACKLASH`. The Ekos loop measures again after every correction, and the 2.0
  compensation did not take effect (each jog replaced the previous one before it finished).
- The closed-loop scripts (`oapa_closed_loop.sh`, `auto_oapa.sh`) are removed: Ekos runs the
  loop itself. `install.sh` deletes the old files.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| **OAPA not listed in Ekos** | Check `ls /usr/share/indi/indi_oapa.xml` |
| **"INDI >= 2.2.0 is required"** | Update INDI from the `ppa:mutlaqja/ppa` repository |
| **Connection fails** | Check the port (`ls /dev/ttyUSB* /dev/ttyACM*`) and that your user is in the `dialout` group |
| **"No OAPA status frame received"** | Flash the OAPA firmware; test with `screen /dev/ttyUSB0 115200` and type `?` |
| **"Azimuth is not calibrated"** | Set **Calibration** for that axis |
| **Axis moves the wrong way** | Enable that axis' **Reverse** switch |
| **"Move ended before reaching the target"** | The platform was stopped from outside, or the firmware reset |
| **"position is not changing"** | Motor stalled or disconnected: check wiring and current |

For logs, enable debug logging for OAPA in the INDI Control Panel: every serial command
(`CMD`) and reply (`RES`) is shown.

---

## License

GNU General Public License v2.0 (see [LICENSE](LICENSE)). The driver sources carry the
LGPL-2.1-or-later header used by INDI core drivers.
