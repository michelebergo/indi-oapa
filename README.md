# INDI AAPA — Astrophilos Astronomical Polar Alignment

An [INDI](https://www.indilib.org/) driver for the **AAPA** (Automated Astronomical Polar Alignment) device — a motorised altitude/azimuth adjustment system built with Arduino + Grbl that lets you polar-align an equatorial mount without touching the knobs.

> **⚠️ Beta Software** — This driver is under active development. Please report any issues on the [GitHub Issues](https://github.com/michelebergo/indi-aapa/issues) page.

---

## Features

- **Ekos Native PAC Support** *(INDI ≥ 2.1.0)* — Implements the standard `AlignmentCorrectionInterface` so Ekos can drive corrections directly
- **Manual Jog Control** — Command azimuth (X) and altitude (Y) motor axes from Ekos / any INDI client
- **Calibration Property** — Configure Steps-Per-Degree for each axis from the INDI control panel
- **Adjustable Speed** — Set the feed rate to match your mount's adjustment sensitivity
- **Abort Button** — Emergency stop for all motion
- **Live Position Readout** — Real-time motor position reported back to the client
- **Closed-Loop Script** *(legacy fallback)* — Shell script bridge for older INDI versions

---

## Hardware Requirements

| Component | Details |
|-----------|---------|
| **AAPA Device** | Motorised alt/az adjustment platform |
| **Controller** | Arduino (Uno/Nano) running Grbl 1.1 firmware |
| **Connection** | USB serial (typically `/dev/ttyUSB0`) |
| **Computer** | Raspberry Pi or Linux PC running INDI / KStars+Ekos |

---

## Installation

### Prerequisites

A Debian/Ubuntu-based Linux system (including Raspberry Pi OS) with INDI already installed. If you don't have INDI yet:

```bash
sudo apt-add-repository ppa:mutlaqja/ppa
sudo apt update
sudo apt install indi-bin libindi-dev
```

### Install the AAPA Driver

```bash
git clone https://github.com/michelebergo/indi-aapa.git
cd indi-aapa
chmod +x install.sh
sudo ./install.sh
```

That's it! The installer will compile the driver and place everything in the correct system paths.

### Uninstall

```bash
sudo ./uninstall.sh
```

---

## Configuration in Ekos / KStars

1. Open **KStars → Ekos → Profile Editor**
2. Click **"Auxiliary"** and select **"AAPA Polar Alignment"** from the driver list
3. Set the serial port (usually `/dev/ttyUSB0`) in the driver's **Port** field
4. Click **Connect**

Once connected you will see:

| Control | Description |
|---------|-------------|
| **Position** | Current X (azimuth) and Y (altitude) in motor steps |
| **Jog** | Enter a relative movement value and press Set |
| **Speed** | Feed rate in mm/min (default: 500) |
| **Calibration** | Steps-per-degree for azimuth and altitude axes |
| **Abort** | Emergency stop |

> With **INDI ≥ 2.1.0**, you will also see the **Alignment Correction** controls (Correct/Abort, Error values, Status light) — these are driven automatically by Ekos PAA.

---

## Ekos Native PAC Integration *(INDI ≥ 2.1.0)*

If built against INDI 2.1.0+ (which includes the `AlignmentCorrectionInterface`), the driver works as a native **Polar Alignment Corrector** device. Ekos's Polar Alignment Assistant will:

1. Send the measured AZ/ALT error in degrees directly to the driver
2. The driver converts degrees to motor jog units using the **Calibration** property
3. Motors execute the correction
4. The driver reports completion when Grbl returns to Idle

No scripts needed — just set the **Calibration** values and let Ekos handle everything.

---

## Closed-Loop Script *(Legacy Fallback)*

For INDI < 2.1.0, the `aapa_closed_loop.sh` script provides the same automation:

1. Edit the calibration constants in `aapa_closed_loop.sh`:

```bash
STEPS_PER_DEG_AZ=50
STEPS_PER_DEG_ALT=50
THRESHOLD_DEG=0.01
```

2. In Profile Editor → Scripts → Post-Startup, point to `auto_aapa.sh`.

---

## Calibrating Steps-Per-Degree

1. Use Ekos Polar Alignment to measure the current error (e.g. 0.5° in azimuth)
2. Manually jog the AAPA by a known amount (e.g. 25 units)
3. Re-solve and measure the new error
4. Calculate: `STEPS_PER_DEG = jog_units / degrees_corrected`
5. Set the values in the driver's **Calibration** property (or in the script for legacy mode)

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| **Driver not listed in Ekos** | Verify the XML is installed: `ls /usr/share/indi/indi_aapa_polaralignment.xml` |
| **Connection fails** | Check the serial port: `ls /dev/ttyUSB*`. Try `sudo chmod 666 /dev/ttyUSB0` |
| **Handshake timeout** | The Arduino may need a longer reset time. Reconnect and wait a few seconds |
| **Motor doesn't move** | Verify Grbl is responding: `screen /dev/ttyUSB0 115200` and type `?` |
| **Wrong direction** | Swap the sign in `STEPS_PER_DEG` or invert motor wiring |

---

## Reporting Bugs

Please open an issue at [github.com/michelebergo/indi-aapa/issues](https://github.com/michelebergo/indi-aapa/issues) with:

- A description of what went wrong
- Your system info (OS, INDI version: `indiserver --version`)
- Relevant log output from `/tmp/aapa_automation.log` (if using closed-loop)
- INDI log output (enable logging in Ekos → INDI Control Panel → Logs)

---

## License

This project is licensed under the [GNU General Public License v2.0](LICENSE) — the standard license for INDI ecosystem drivers.
