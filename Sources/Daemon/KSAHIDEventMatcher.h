#ifndef KSA_HID_EVENT_MATCHER_H
#define KSA_HID_EVENT_MATCHER_H

#include <stdbool.h>
#include <stdint.h>

bool KSAHIDEventIsPowerButtonDown(uint32_t eventType,
                                  int64_t usagePage,
                                  int64_t usage,
                                  int64_t down);

#endif
