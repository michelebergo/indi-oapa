/**
 * FYSETC E4 v1.3 - Serial Communication for NINA TPPA Plugin
 * Serial Communication: 115200 baud
 * GRBL compatible protocol for NINA
 */

#include <Arduino.h>
#include <TMCStepper.h>
#include <AccelStepper.h>

#define ENABLE_PIN 25

// --- TMC2209 ADDRESSES ---
#define X_ADDR      1
#define Y_ADDR      3

// --- PINOUT ---
#define X_STEP_PIN 27
#define X_DIR_PIN  26
#define Y_STEP_PIN 33
#define Y_DIR_PIN  32

// --- ENDSTOPS ---
// FYSETC E4 has X-min (GPIO34), Y-min (GPIO35), Z-min ports available
#define X_ENDSTOP_PIN 34  // Using X-min port for ALT (elevation) axis homing
// Y-min port (GPIO35): Not used - azimuth has 360° free rotation
// Z-min port: Available if needed for future expansion

// --- UART ---
#define SERIAL_PORT Serial1
#define DRIVER_UART_RX 21
#define DRIVER_UART_TX 22
#define R_SENSE 0.11f

// --- OBJECTS ---
TMC2209Stepper driverX(&SERIAL_PORT, R_SENSE, X_ADDR);
TMC2209Stepper driverY(&SERIAL_PORT, R_SENSE, Y_ADDR);

AccelStepper stepperX(AccelStepper::DRIVER, X_STEP_PIN, X_DIR_PIN);
AccelStepper stepperY(AccelStepper::DRIVER, Y_STEP_PIN, Y_DIR_PIN);

// --- STATE ---
float x_position = 0.0;  // Current X position in steps
float y_position = 0.0;  // Current Y position in steps
String machineStatus = "Idle";
bool isHomed = false;     // System homed status
bool isHoming = false;    // Currently executing homing
String serialBuffer = ""; // Non-blocking serial command buffer

// --- CONFIGURATION ---
int x_run_ma = 600;
float x_hold_mult = 0.5;
int x_microsteps = 16;

int y_run_ma = 600;
float y_hold_mult = 0.5;
int y_microsteps = 16;

// --- HOMING CONFIGURATION ---
const int HOMING_SPEED = 800;      // Speed for homing movement
const int HOMING_BACKOFF = 50;     // Steps to back off after hitting endstop
const bool X_ENDSTOP_INVERT = false; // Set true if endstop is normally closed
// Y axis has 360° free rotation, no endstop configuration needed

// --- DRIVER FUNCTIONS ---
void apply_current_x() { driverX.rms_current(x_run_ma, x_hold_mult); }
void apply_current_y() { driverY.rms_current(y_run_ma, y_hold_mult); }

// --- ENDSTOP FUNCTIONS ---
bool isXEndstopTriggered() {
  return digitalRead(X_ENDSTOP_PIN) == (X_ENDSTOP_INVERT ? LOW : HIGH);
}

// Y axis (azimuth) has no endstop - 360° free rotation

// --- HOMING FUNCTION ---
void performHoming() {
  isHoming = true;
  machineStatus = "Home";
  
  Serial.println("Starting homing sequence...");
  
  // Home X axis (ALT - Elevation)
  Serial.println("Homing X axis (Elevation)...");
  stepperX.setSpeed(-HOMING_SPEED); // Move toward home (negative direction)
  while (!isXEndstopTriggered()) {
    stepperX.runSpeed();
  }
  stepperX.stop();
  delay(100);
  
  // Back off from endstop
  stepperX.move(HOMING_BACKOFF);
  while (stepperX.distanceToGo() != 0) {
    stepperX.run();
  }
  
  // Set home position
  stepperX.setCurrentPosition(0);
  x_position = 0.0;
  Serial.println("X axis homed");
  
  // Y axis (Azimuth) - No homing needed (360° free rotation)
  Serial.println("Y axis: No homing (360° free rotation)");
  stepperY.setCurrentPosition(0);
  y_position = 0.0;
  
  isHomed = true;
  isHoming = false;
  machineStatus = "Idle";
  Serial.println("Homing complete");
  Serial.println("ok");
}

// --- GRBL-STYLE STATUS FUNCTION ---
void sendStatus() {
  // Update positions
  x_position = stepperX.currentPosition();
  y_position = stepperY.currentPosition();
  
  // Determine status
  if (isHoming) {
    machineStatus = "Home";
  } else if (stepperX.isRunning() || stepperY.isRunning()) {
    machineStatus = "Run";
  } else {
    machineStatus = "Idle";
  }
  
  // GRBL Format: <Status|MPos:x,y,z|
  Serial.print("<");
  Serial.print(machineStatus);
  Serial.print("|MPos:");
  Serial.print(x_position, 2);
  Serial.print(",");
  Serial.print(y_position, 2);
  Serial.println(",0.00|>");
  Serial.println("ok");
}

// --- COMMAND PARSER ---
String parseCommand(String input) {
  input.trim();
  String response = "ok";
  if (input.length() == 0) return "";

  // GRBL Status Command
  if (input.charAt(0) == '?') {
    sendStatus();
    return "";
  }

  // GRBL Homing Command
  if (input.startsWith("$H")) {
    performHoming();
    return "";
  }

  // GRBL Jog Commands: $J=G91G21X10F100 or $J=G53X10F100
  if (input.startsWith("$J=")) {
    return parseGRBLJog(input.substring(3));
  }

  if (input.length() < 2) return "error";
  char firstChar = input.charAt(0);
  
  // Direct Movement (e.g. X800 for steps)
  if ((firstChar == 'X' || firstChar == 'x' || firstChar == 'Y' || firstChar == 'y') && 
      (isdigit(input.charAt(1)) || input.charAt(1) == '-')) {
      long steps = input.substring(1).toInt();
      if (firstChar == 'X' || firstChar == 'x') { 
        stepperX.move(steps);
        response = "ok";
      } else { 
        stepperY.move(steps);
        response = "ok";
      }
      return response;
  }

  // Config Commands (CX, SX, HX...)
  if (input.length() > 2) {
      char type = firstChar; char axis = input.charAt(1);
      int val = input.substring(2).toInt();

      if (type == 'C' || type == 'c') {
        if (axis == 'X' || axis == 'x') { x_run_ma = val; apply_current_x(); }
        else { y_run_ma = val; apply_current_y(); }
        response = "ok";
      }
      else if (type == 'H' || type == 'h') {
        float mult = val / 100.0;
        if (axis == 'X' || axis == 'x') { x_hold_mult = mult; apply_current_x(); }
        else { y_hold_mult = mult; apply_current_y(); }
        response = "ok";
      }
      else if (type == 'S' || type == 's') {
        if (axis == 'X' || axis == 'x') { driverX.microsteps(val); x_microsteps = val; }
        else { driverY.microsteps(val); y_microsteps = val; }
        response = "ok";
      }
  }
  return response;
}

// --- GRBL JOG PARSER ---
String parseGRBLJog(String cmd) {
  // Examples: G91G21X10F100 (relative) or G53X10F100 (absolute)
  bool isRelative = cmd.indexOf("G91") >= 0;
  bool isAbsolute = cmd.indexOf("G53") >= 0;
  
  float xVal = 0, yVal = 0;
  bool hasX = false, hasY = false;
  
  // Parse X
  int xPos = cmd.indexOf('X');
  if (xPos >= 0) {
    hasX = true;
    int nextChar = xPos + 1;
    while (nextChar < cmd.length() && (isdigit(cmd.charAt(nextChar)) || cmd.charAt(nextChar) == '.' || cmd.charAt(nextChar) == '-')) nextChar++;
    xVal = cmd.substring(xPos + 1, nextChar).toFloat();
  }
  
  // Parse Y
  int yPos = cmd.indexOf('Y');
  if (yPos >= 0) {
    hasY = true;
    int nextChar = yPos + 1;
    while (nextChar < cmd.length() && (isdigit(cmd.charAt(nextChar)) || cmd.charAt(nextChar) == '.' || cmd.charAt(nextChar) == '-')) nextChar++;
    yVal = cmd.substring(yPos + 1, nextChar).toFloat();
  }
  
  // Execute movement
  if (isRelative) {
    if (hasX) stepperX.move((long)xVal);
    if (hasY) stepperY.move((long)yVal);
  } else if (isAbsolute) {
    if (hasX) stepperX.moveTo((long)xVal);
    if (hasY) stepperY.moveTo((long)yVal);
  }
  
  return "ok";
}

void setup() {
  Serial.begin(115200);
  SERIAL_PORT.begin(115200, SERIAL_8N1, DRIVER_UART_RX, DRIVER_UART_TX);

  pinMode(ENABLE_PIN, OUTPUT); digitalWrite(ENABLE_PIN, LOW);
  
  // Setup endstop with pullup resistor (X axis only - elevation)
  pinMode(X_ENDSTOP_PIN, INPUT_PULLUP);
  // Y axis (azimuth) has 360° free rotation, no endstop

  driverX.begin(); driverX.toff(5); driverX.microsteps(x_microsteps); driverX.pwm_autoscale(true); apply_current_x();
  driverY.begin(); driverY.toff(5); driverY.microsteps(y_microsteps); driverY.pwm_autoscale(true); apply_current_y();

  stepperX.setMaxSpeed(2000); stepperX.setAcceleration(1000);
  stepperY.setMaxSpeed(2000); stepperY.setAcceleration(1000);

  Serial.println("\n--- FYSETC E4 READY ---");
  Serial.println("OAPA System Initialized");
  Serial.println("Send $H to home elevation axis");
  Serial.println("Azimuth: 360° free rotation (no homing)");
  Serial.println("Waiting for commands...");
}

void loop() {
  // Safety: Stop X axis if endstop triggered during movement (except while homing)
  // Y axis has no endstop (360° free rotation)
  // TEMPORARILY DISABLED for testing - endstop pin may be floating or incorrectly wired
  // if (!isHoming) {
  //   if (isXEndstopTriggered() && stepperX.speed() < 0) stepperX.stop();
  // }

  // CRITICAL: Must call run() continuously for motors to move
  stepperX.run();
  stepperY.run();

  // NON-BLOCKING serial read - read ONLY ONE character per loop iteration
  // This ensures run() is called frequently enough for smooth motor movement
  if (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      // Command complete - process it
      if (serialBuffer.length() > 0) {
        String result = parseCommand(serialBuffer);
        if (result.length() > 0) Serial.println(result);
        serialBuffer = "";  // Clear buffer for next command
      }
    } else {
      // Add character to buffer
      serialBuffer += c;
    }
  }
}