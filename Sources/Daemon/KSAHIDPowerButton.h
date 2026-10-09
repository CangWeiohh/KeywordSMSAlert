//
//  KSAHIDPowerButton.h
//  Event-driven physical power-button observer for the standalone alert daemon.
//

#ifndef KSA_HID_POWER_BUTTON_H
#define KSA_HID_POWER_BUTTON_H

#import <Foundation/Foundation.h>
#import "KSAHIDEventMatcher.h"

/// The pure matcher is declared in KSAHIDEventMatcher.h for host tests.

@interface KSAHIDPowerButton : NSObject

@property (atomic, readonly, getter=isAvailable) BOOL available;

+ (instancetype)sharedInstance;
- (void)start;

@end

#endif
