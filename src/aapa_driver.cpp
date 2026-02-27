#include "aapa_driver.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <termios.h>

#include <libindi/indicom.h>
#include <libindi/inditimer.h>
#include <libindi/indilogger.h>

// 1 second polling interval
#define POLL_MS 1000

// We declare an auto pointer to the device.
static std::unique_ptr<AAPA> aapaDevice(new AAPA());

AAPA::AAPA()
#ifdef HAVE_ALIGNMENT_CORRECTION_INTERFACE
    : ACI(this)
#endif
{
    PortFD = -1;
    setVersion(1, 1);
}

const char *AAPA::getDefaultName()
{
    return "AAPA Polar Alignment";
}

bool AAPA::initProperties()
{
    // Initialize standard properties
    INDI::DefaultDevice::initProperties();

#ifdef HAVE_ALIGNMENT_CORRECTION_INTERFACE
    // Initialize PAC interface properties
    ACI::initProperties(MAIN_CONTROL_TAB);

    // Register as Auxiliary + Alignment Correction device
    setDriverInterface(AUX_INTERFACE | ALIGNMENT_CORRECTION_INTERFACE);
#endif

    // Position (Read Only)
    IUFillNumber(&PositionN[0], "X_POS", "Azimuth", "%6.2f", 0, 10000, 0, 0);
    IUFillNumber(&PositionN[1], "Y_POS", "Altitude", "%6.2f", 0, 10000, 0, 0);
    IUFillNumberVector(&PositionNP, PositionN, 2, getDeviceName(), "AAPA_POSITION", "Position", MAIN_CONTROL_TAB, IP_RO, 0, IPS_IDLE);

    // Jog Control (Write Only)
    IUFillNumber(&JogN[0], "X_JOG", "Azimuth Relative", "%6.2f", -10000, 10000, 0, 0);
    IUFillNumber(&JogN[1], "Y_JOG", "Altitude Relative", "%6.2f", -10000, 10000, 0, 0);
    IUFillNumberVector(&JogNP, JogN, 2, getDeviceName(), "AAPA_JOG", "Jog", MAIN_CONTROL_TAB, IP_WO, 0, IPS_IDLE);

    // Speed setting
    IUFillNumber(&SpeedN[0], "JOG_SPEED", "Speed", "%6.0f", 1, 10000, 0, 500);
    IUFillNumberVector(&SpeedNP, SpeedN, 1, getDeviceName(), "AAPA_SPEED", "Speed Configuration", MAIN_CONTROL_TAB, IP_RW, 0, IPS_IDLE);

    // Steps-per-degree calibration
    IUFillNumber(&StepsPerDegN[0], "AZ_STEPS", "Azimuth Steps/Deg", "%6.1f", 0.1, 10000, 1, 50);
    IUFillNumber(&StepsPerDegN[1], "ALT_STEPS", "Altitude Steps/Deg", "%6.1f", 0.1, 10000, 1, 50);
    IUFillNumberVector(&StepsPerDegNP, StepsPerDegN, 2, getDeviceName(), "AAPA_STEPS_PER_DEG",
                       "Calibration", MAIN_CONTROL_TAB, IP_RW, 0, IPS_IDLE);

    // PAA Error Input: write Ekos PAA result here to trigger auto-correction
    IUFillNumber(&PAAErrorN[0], "AZ_ERR", "Azimuth Error (deg)", "%.6f", -180, 180, 0, 0);
    IUFillNumber(&PAAErrorN[1], "ALT_ERR", "Altitude Error (deg)", "%.6f", -90, 90, 0, 0);
    IUFillNumberVector(&PAAErrorNP, PAAErrorN, 2, getDeviceName(), "AAPA_PAA_ERROR",
                       "PAA Error Input", MAIN_CONTROL_TAB, IP_WO, 0, IPS_IDLE);

    // Abort button
    IUFillSwitch(&AbortS[0], "ABORT", "Abort", ISS_OFF);
    IUFillSwitchVector(&AbortSP, AbortS, 1, getDeviceName(), "AAPA_ABORT", "Abort Motion", MAIN_CONTROL_TAB, IP_WO, ISR_ATMOST1, 0, IPS_IDLE);

    // Port definition
    IUFillText(&PortT[0], "PORT", "Port", "/dev/ttyUSB0");
    IUFillTextVector(&PortTP, PortT, 1, getDeviceName(), "DEVICE_PORT", "Ports", MAIN_CONTROL_TAB, IP_RW, 60, IPS_IDLE);

    // Add standard connection properties
    addAuxControls();

    return true;
}

void AAPA::ISGetProperties(const char *dev)
{
    INDI::DefaultDevice::ISGetProperties(dev);

    // If connected, pass these properties to the client
    if (isConnected()) {
        defineProperty(&PositionNP);
        defineProperty(&JogNP);
        defineProperty(&SpeedNP);
        defineProperty(&StepsPerDegNP);
        defineProperty(&PAAErrorNP);
        defineProperty(&AbortSP);
    }
    defineProperty(&PortTP);
}

bool AAPA::updateProperties()
{
    INDI::DefaultDevice::updateProperties();
    
    if (isConnected()) {
        defineProperty(&PositionNP);
        defineProperty(&JogNP);
        defineProperty(&SpeedNP);
        defineProperty(&StepsPerDegNP);
        defineProperty(&AbortSP);
    } else {
        deleteProperty(PositionNP.name);
        deleteProperty(JogNP.name);
        deleteProperty(SpeedNP.name);
        deleteProperty(StepsPerDegNP.name);
        deleteProperty(PAAErrorNP.name);
        deleteProperty(AbortSP.name);
    }

#ifdef HAVE_ALIGNMENT_CORRECTION_INTERFACE
    ACI::updateProperties();
#endif
    
    return true;
}

bool AAPA::saveConfigItems(FILE *fp)
{
    INDI::DefaultDevice::saveConfigItems(fp);
    IUSaveConfigNumber(fp, &SpeedNP);
    IUSaveConfigNumber(fp, &StepsPerDegNP);
    IUSaveConfigText(fp, &PortTP);
    return true;
}

bool AAPA::Connect()
{
    const char *port = PortT[0].text;
    LOGF_INFO("Attempting to connect to AAPA on %s", port);
    
    // Connect to serial port at 115200 baud, 8N1
    if (tty_connect(port, 115200, 8, 0, 1, &PortFD) != TTY_OK) {
        LOGF_ERROR("Failed to connect to port %s", port);
        return false;
    }
    LOG_INFO("Serial connection opened, waiting for Arduino reset...");
    
    // Wait for 3.0s after connection to allow Arduino Grbl firmware/ESP32 to reset
    usleep(3000000);
    
    // Confirm connection
    if (!Handshake()) {
        LOG_ERROR("Failed to handshake with AAPA");
        tty_disconnect(PortFD);
        PortFD = -1;
        return false;
    }
    
    LOGF_INFO("Connected to AAPA on %s", port);
    
    // Set periodic timer to capture status
    SetTimer(POLL_MS);
    return true;
}

bool AAPA::Disconnect()
{
    m_CorrectionInProgress = false;

    if (PortFD > 0) {
        tty_disconnect(PortFD);
        PortFD = -1;
    }
    
    LOG_INFO("Disconnected from AAPA");
    return true;
}

bool AAPA::Handshake()
{
    char buf[512];
    int nbytes = 0;
    
    // Purge any stale data from serial buffer instead of blocking read loop
    tcflush(PortFD, TCIOFLUSH);

    // Send standard GRBL reset/status command
    LOG_INFO("Sending ? to initiate handshake");
    sendCommand("?");
    
    // Wait for response, reading chunks since Grbl prints a welcome message sometimes
    int totalBytes = 0;
    int retries = 50; // Max 50 chunks to prevent infinite loop
    while(totalBytes < (int)sizeof(buf) - 2 && retries-- > 0) {
        int bytes_read = 0;
        if (tty_read(PortFD, buf + totalBytes, 1, 1, &bytes_read) == TTY_OK && bytes_read > 0) {
             totalBytes += bytes_read;
             buf[totalBytes] = '\0';
             if (strstr(buf, "<") != nullptr) {
                 LOGF_INFO("Handshake success, received: %s", buf);
                 // clear remaining buffer
                 tcflush(PortFD, TCIOFLUSH);
                 return true;
             }
        } else {
             break; // Timeout or error
        }
    }
    
    LOGF_ERROR("Handshake read timeout or error. Buffer contents: %s", buf);
    return false;
}

void AAPA::sendCommand(const char *cmd)
{
    if (PortFD < 0) return;
    
    char sendBuf[128];
    snprintf(sendBuf, sizeof(sendBuf), "%s\n", cmd);
    
    int nbytes;
    tty_write(PortFD, sendBuf, strlen(sendBuf), &nbytes);
}

void AAPA::jogAxis(const char *axis, double units, double speed)
{
    char cmd[128];
    snprintf(cmd, sizeof(cmd), "$J=G91G21%s%.2fF%.0f", axis, units, speed);
    sendCommand(cmd);
    LOGF_INFO("Jogging %s: %.2f at F%.0f", axis, units, speed);
}

bool AAPA::updateDeviceStatus()
{
    if (PortFD < 0) return false;
    
    // Send status query
    sendCommand("?");
    
    char buf[256];
    int nbytes;
    
    // Read up to newline
    if (tty_read_section(PortFD, buf, '\n', 1, &nbytes) == TTY_OK) {
        buf[nbytes] = '\0';
        
        // Typical GRBL status: <Idle|MPos:0.000,0.000,0.000|...>
        if (buf[0] == '<') {
            // Check if Grbl is Idle (needed for correction completion)
            bool isIdle = (strstr(buf, "Idle") != nullptr);

            char *mpos = strstr(buf, "MPos:");
            if (mpos) {
                float x = 0, y = 0, z = 0;
                if (sscanf(mpos, "MPos:%f,%f,%f", &x, &y, &z) >= 2) {
                    PositionN[0].value = x;
                    PositionN[1].value = y;
                    
                    IDSetNumber(&PositionNP, nullptr);
                }
            }

#ifdef HAVE_ALIGNMENT_CORRECTION_INTERFACE
            // If a correction was in progress and Grbl is now idle, report completion
            if (m_CorrectionInProgress && isIdle) {
                m_CorrectionInProgress = false;
                LOG_INFO("Alignment correction completed successfully.");
                CorrectionSP.setState(IPS_OK);
                CorrectionSP.reset();
                CorrectionSP.apply();
                CorrectionStatusLP[0].setState(IPS_OK);
                CorrectionStatusLP.apply();
            }
#endif
            return true;
        }
    }
    
    return false;
}

void AAPA::TimerHit()
{
    if (!isConnected()) return;
    
    updateDeviceStatus();
    
    // Re-arm timer
    SetTimer(POLL_MS);
}

bool AAPA::ISNewNumber(const char *dev, const char *name, double values[], char *names[], int n)
{
    if (strcmp(dev, getDeviceName()) != 0)
        return false;

#ifdef HAVE_ALIGNMENT_CORRECTION_INTERFACE
    // Delegate to AlignmentCorrectionInterface first
    if (ACI::processNumber(dev, name, values, names, n))
        return true;
#endif

    if (strcmp(name, JogNP.name) == 0) {
        JogNP.s = IPS_BUSY;
        IDSetNumber(&JogNP, nullptr);
        
        double x_jog = 0, y_jog = 0;
        
        for (int i = 0; i < n; i++) {
            if (strcmp(names[i], "X_JOG") == 0) {
                x_jog = values[i];
                JogN[0].value = 0; // Reset UI
            } else if (strcmp(names[i], "Y_JOG") == 0) {
                y_jog = values[i];
                JogN[1].value = 0; // Reset UI
            }
        }
        
        double speed = SpeedN[0].value;
        
        if (x_jog != 0)
            jogAxis("X", x_jog, speed);
        
        if (y_jog != 0)
            jogAxis("Y", y_jog, speed);
        
        JogNP.s = IPS_OK;
        IDSetNumber(&JogNP, nullptr);
        
        return true;
    }
    
    if (strcmp(name, SpeedNP.name) == 0) {
        IUUpdateNumber(&SpeedNP, values, names, n);
        SpeedNP.s = IPS_OK;
        IDSetNumber(&SpeedNP, nullptr);
        return true;
    }

    if (strcmp(name, StepsPerDegNP.name) == 0) {
        IUUpdateNumber(&StepsPerDegNP, values, names, n);
        StepsPerDegNP.s = IPS_OK;
        IDSetNumber(&StepsPerDegNP, nullptr);
        LOGF_INFO("Calibration updated: Az=%.1f Alt=%.1f steps/deg",
                  StepsPerDegN[0].value, StepsPerDegN[1].value);
        return true;
    }

    // PAA Error: convert degrees to steps and auto-correct
    if (strcmp(name, PAAErrorNP.name) == 0) {
        double az_err = 0, alt_err = 0;
        for (int i = 0; i < n; i++) {
            if (strcmp(names[i], "AZ_ERR") == 0) az_err = values[i];
            else if (strcmp(names[i], "ALT_ERR") == 0) alt_err = values[i];
        }
        double az_steps  = -az_err  * StepsPerDegN[0].value;
        double alt_steps = -alt_err * StepsPerDegN[1].value;
        double speed = SpeedN[0].value;
        LOGF_INFO("PAA correction: az_err=%.4f deg -> %.0f steps | alt_err=%.4f deg -> %.0f steps",
                  az_err, az_steps, alt_err, alt_steps);
        PAAErrorNP.s = IPS_BUSY;
        IDSetNumber(&PAAErrorNP, nullptr);
        if (az_steps != 0)  jogAxis("X", az_steps, speed);
        if (alt_steps != 0) jogAxis("Y", alt_steps, speed);
        PAAErrorNP.s = IPS_OK;
        IDSetNumber(&PAAErrorNP, nullptr);
        return true;
    }

    return INDI::DefaultDevice::ISNewNumber(dev, name, values, names, n);
}

bool AAPA::ISNewSwitch(const char *dev, const char *name, ISState *states, char *names[], int n)
{
    if (strcmp(dev, getDeviceName()) != 0)
        return false;

#ifdef HAVE_ALIGNMENT_CORRECTION_INTERFACE
    // Delegate to AlignmentCorrectionInterface first
    if (ACI::processSwitch(dev, name, states, names, n))
        return true;
#endif

    if (strcmp(name, AbortSP.name) == 0) {
        IUUpdateSwitch(&AbortSP, states, names, n);
        
        if (AbortS[0].s == ISS_ON) {
            // GRBL abort command: Feed Hold (!) followed by Reset (\x18)
            sendCommand("!");
            // Wait a little, then issue soft-reset
            usleep(50000); 
            char resetCmd[2] = {0x18, 0};
            sendCommand(resetCmd);
            
            m_CorrectionInProgress = false;
            LOG_INFO("Motion aborted.");
            
            AbortS[0].s = ISS_OFF;
            AbortSP.s = IPS_OK;
            IDSetSwitch(&AbortSP, nullptr);
        }
        
        return true;
    }

    return INDI::DefaultDevice::ISNewSwitch(dev, name, states, names, n);
}

bool AAPA::ISNewText(const char *dev, const char *name, char *texts[], char *names[], int n)
{
    if (strcmp(dev, getDeviceName()) != 0)
        return false;

    if (strcmp(name, PortTP.name) == 0) {
        IUUpdateText(&PortTP, texts, names, n);
        PortTP.s = IPS_OK;
        IDSetText(&PortTP, nullptr);
        return true;
    }

    return INDI::DefaultDevice::ISNewText(dev, name, texts, names, n);
}

// ═══════════════════════════════════════════════════════════════
//  AlignmentCorrectionInterface Implementation
// ═══════════════════════════════════════════════════════════════

#ifdef HAVE_ALIGNMENT_CORRECTION_INTERFACE

IPState AAPA::StartCorrection(double azError, double altError)
{
    if (!isConnected()) {
        LOG_ERROR("Cannot start correction: not connected.");
        return IPS_ALERT;
    }

    if (m_CorrectionInProgress) {
        LOG_WARN("Correction already in progress.");
        return IPS_BUSY;
    }

    double stepsAz  = StepsPerDegN[0].value;
    double stepsAlt = StepsPerDegN[1].value;
    double speed    = SpeedN[0].value;

    // Convert error in degrees to motor jog units
    // Negative sign: we want to CORRECT the error, not add to it
    double jogAz  = -azError  * stepsAz;
    double jogAlt = -altError * stepsAlt;

    LOGF_INFO("Starting alignment correction: Az error=%.4f° (jog %.2f), Alt error=%.4f° (jog %.2f)",
              azError, jogAz, altError, jogAlt);

    if (fabs(jogAz) > 0.01)
        jogAxis("X", jogAz, speed);

    if (fabs(jogAlt) > 0.01)
        jogAxis("Y", jogAlt, speed);

    m_CorrectionInProgress = true;

    // TimerHit/updateDeviceStatus will detect Grbl Idle state
    // and set CorrectionSP/CorrectionStatusLP to OK automatically
    return IPS_BUSY;
}

IPState AAPA::AbortCorrection()
{
    if (!isConnected()) {
        LOG_ERROR("Cannot abort: not connected.");
        return IPS_ALERT;
    }

    // GRBL feed-hold + soft-reset
    sendCommand("!");
    usleep(50000);
    char resetCmd[2] = {0x18, 0};
    sendCommand(resetCmd);

    m_CorrectionInProgress = false;
    LOG_INFO("Alignment correction aborted.");

    return IPS_OK;
}

#endif // HAVE_ALIGNMENT_CORRECTION_INTERFACE
