#ifndef AAPA_DRIVER_H
#define AAPA_DRIVER_H

#include <libindi/defaultdevice.h>
#include <libindi/inditimer.h>

// Detect new AlignmentCorrectionInterface (INDI >= 2.1.0, PR #2342)
#if __has_include(<libindi/indialignmentcorrectioninterface.h>)
#include <libindi/indialignmentcorrectioninterface.h>
#define HAVE_ALIGNMENT_CORRECTION_INTERFACE 1
#endif

class AAPA : public INDI::DefaultDevice
#ifdef HAVE_ALIGNMENT_CORRECTION_INTERFACE
    , public INDI::AlignmentCorrectionInterface
#endif
{
    // Alias for shorter notation in .cpp
#ifdef HAVE_ALIGNMENT_CORRECTION_INTERFACE
    using ACI = INDI::AlignmentCorrectionInterface;
#endif

public:
    AAPA();
    virtual ~AAPA() = default;

    virtual const char *getDefaultName() override;
    virtual bool initProperties() override;
    virtual void ISGetProperties(const char *dev) override;
    virtual bool updateProperties() override;
    virtual bool saveConfigItems(FILE *fp) override;

    virtual bool ISNewNumber(const char *dev, const char *name, double values[], char *names[], int n) override;
    virtual bool ISNewSwitch(const char *dev, const char *name, ISState *states, char *names[], int n) override;
    virtual bool ISNewText(const char *dev, const char *name, char *texts[], char *names[], int n) override;

protected:
    virtual bool Connect() override;
    virtual bool Disconnect() override;
    virtual void TimerHit() override;
    virtual bool Handshake();

#ifdef HAVE_ALIGNMENT_CORRECTION_INTERFACE
    // From AlignmentCorrectionInterface
    virtual IPState StartCorrection(double azError, double altError) override;
    virtual IPState AbortCorrection() override;
#endif

private:
    bool updateDeviceStatus();
    void sendCommand(const char *cmd);
    void jogAxis(const char *axis, double units, double speed);

    // Number properties for actual positions
    INumberVectorProperty PositionNP;
    INumber PositionN[2];

    // Number properties for relative jogging
    INumberVectorProperty JogNP;
    INumber JogN[2];
    
    // Number property for Feed Rate/Speed
    INumberVectorProperty SpeedNP;
    INumber SpeedN[1];

    // Number property for Steps-Per-Degree calibration
    INumberVectorProperty StepsPerDegNP;
    INumber StepsPerDegN[2];

    // Switch property to stop motion
    ISwitchVectorProperty AbortSP;
    ISwitch AbortS[1];

    ITextVectorProperty PortTP;
    IText PortT[1];

    int PortFD;

    // Tracking correction state
    bool m_CorrectionInProgress{false};
};

#endif // AAPA_DRIVER_H
