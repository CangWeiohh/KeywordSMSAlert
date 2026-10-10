#include "KSAHIDEventMatcher.h"

// The physical lock/power button is reported as a HID keyboard-class event (type 3).
// Which usage it carries depends on the device; these are the three candidates found in
// the wild, so all of them are accepted:
//
//   Consumer page 0x0C   / usage 0x30  -> kHIDUsage_Csmr_Power
//   AppleVendor page 0xFF01 / usage 0x0B -> "Screensave", how the iPhone lock button is
//                                           usually reported
//   Keyboard page 0x07   / usage 0x66  -> kHIDUsage_KeyboardPower
//
// Anything else (volume, home, media keys ...) is rejected, so the alert can never be
// stopped by the wrong button.
bool KSAHIDEventIsPowerButtonDown(uint32_t eventType,
                                  int64_t usagePage,
                                  int64_t usage,
                                  int64_t down)
{
    if (eventType != 3 || down == 0) {
        return false;
    }

    if (usagePage == 0x0C && usage == 0x30) {
        return true;    // Consumer / Power
    }
    if (usagePage == 0xFF01 && usage == 0x0B) {
        return true;    // AppleVendor / Screensave (the iPhone lock button)
    }
    if (usagePage == 0x07 && usage == 0x66) {
        return true;    // Keyboard / Power
    }
    return false;
}
