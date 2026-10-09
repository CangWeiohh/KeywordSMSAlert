#include "KSAHIDEventMatcher.h"

bool KSAHIDEventIsPowerButtonDown(uint32_t eventType,
                                  int64_t usagePage,
                                  int64_t usage,
                                  int64_t down)
{
    return eventType == 3 && usagePage == 0x0C && usage == 0x30 && down != 0;
}
