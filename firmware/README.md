# OAPA Firmware - Arduino ESP32

## Description

GRBL-compatible firmware for FYSETC E4 v1.3 (ESP32) controlling a 2-axis automated polar alignment system.

## Hardware Requirements

- **Board:** FYSETC E4 v1.3 or compatible ESP32 board
- **Drivers:** 2× TMC2209 (UART mode)
- **Motors:** 2× NEMA 17 stepper motors
- **Endstop:** 1× mechanical or optical switch (elevation axis)
- **Power:** 12V or 24V, minimum 2A

## Pin Configuration (FYSETC E4 v1.3)

```cpp
// Stepper Pins
X_STEP_PIN = 27  // Elevation axis
X_DIR_PIN  = 26
Y_STEP_PIN = 33  // Azimuth axis
Y_DIR_PIN  = 32

// Endstops
X_ENDSTOP_PIN = 34  // GPIO34 (X-min port) - Elevation home
// Y-min (GPIO35) - Not used, azimuth has 360° free rotation

// TMC2209 UART
DRIVER_UART_RX = 15
DRIVER_UART_TX = 15

// Enable Pin
ENABLE_PIN = 25
```

## Default Configuration

```cpp
// Motor currents
x_run_ma = 600        // 600mA RMS run current
y_run_ma = 600
x_hold_mult = 0.5     // 50% hold current
y_hold_mult = 0.5

// Microstepping
x_microsteps = 16
y_microsteps = 16

// Motion
MAX_SPEED = 2000      // steps/sec
ACCELERATION = 1000   // steps/sec²

// Homing
HOMING_SPEED = 800
HOMING_BACKOFF = 50
```

## Supported Commands

### GRBL Standard Commands

```
?                       # Status query
$H                      # Home elevation axis (azimuth just resets to zero)
$J=G91G21X100F100      # Jog relative
$J=G53X50F100          # Jog absolute
```

### Custom Configuration Commands

```
XC<value>              # Set X run current (mA)
YC<value>              # Set Y run current (mA)
XH<value>              # Set X hold current (% of run)
YH<value>              # Set Y hold current (% of run)
XS<value>              # Set X microstepping
YS<value>              # Set Y microstepping
```

### Simple Movement Commands

```
X<steps>               # Move X axis (elevation)
Y<steps>               # Move Y axis (azimuth)
```

## Installation

1. Install [Arduino IDE](https://www.arduino.cc/en/software)
2. Add ESP32 board support:
   - File → Preferences → Additional Board Manager URLs:
   ```
   https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
   ```
3. Install required libraries:
   - TMCStepper (0.7.x) by teemuatlut
   - AccelStepper by Mike McCauley

4. Open `oapa_control.ino`
5. Select **Tools → Board → ESP32 Dev Module**
6. Select your COM port
7. Click **Upload**

## Testing

### Serial Monitor Test (115200 baud)

```
> ?
< <Idle|MPos:0.00,0.00,0.00|>
< ok

> $H
< Starting homing sequence...
< Homing X axis (Elevation)...
< X axis homed
< Y axis: No homing (360° free rotation)
< Homing complete
< ok

> X100
< ok

> ?
< <Idle|MPos:100.00,0.00,0.00|>
< ok
```

## Customization

### Adjust Motor Current

```cpp
// In firmware (before upload):
int x_run_ma = 800;  // Increase to 800mA for more torque

// Or via serial (after upload):
XC800  // Set X axis to 800mA
```

### Invert Endstop Logic

```cpp
const bool X_ENDSTOP_INVERT = true;  // For normally-closed switches
```

### Change Homing Speed

```cpp
const int HOMING_SPEED = 1000;  // Faster homing
const int HOMING_BACKOFF = 100; // Back off more from endstop
```

## Troubleshooting

**Motor doesn't move:**
- Check wiring (A+/A- and B+/B- to motor coils)
- Verify power supply is connected
- Try reducing current: `XC400`

**Motor moves wrong direction:**
- Swap motor coil wiring OR
- Invert in NINA settings

**No serial response:**
- Check baud rate is 115200
- Try pressing reset button
- Verify USB cable is data-capable

**Endstop not working:**
- Check wiring to GPIO34 (X-min port)
- Test with multimeter in continuity mode
- Try inverting: `X_ENDSTOP_INVERT = true`

## License

MIT License - See repository root LICENSE file
