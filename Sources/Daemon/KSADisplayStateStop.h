//
//  KSADisplayStateStop.h
//
//  Fallback stop source used ONLY when the IOHID power-button observer could not be
//  registered (e.g. the HID entitlement was not honoured on this device).
//
//  It is deliberately event driven and injection free: two Darwin notifications that
//  need no entitlement at all.
//
//    com.apple.iokit.hid.displayStatus   state 1 = display on,  0 = display off
//    com.apple.springboard.lockstate     state 1 = locked
//
//  Evidence: gsora/BatteryDaemon (a real daemon) registers exactly
//  "com.apple.iokit.hid.displayStatus" with notify_register_dispatch and reads the
//  state with notify_get_state; SagerNet/sing-box-for-apple does the same for both
//  names. Neither needs an entitlement.
//
//  Semantics: while an alert is running, any display on/off transition stops it.
//    * screen ON  + power press -> display goes off   (lock)
//    * screen OFF + power press -> display goes on    (wake)
//  Both are exactly "the user pressed the power button". A raise-to-wake also
//  triggers it, which is harmless: the user is picking the phone up anyway.
//

#ifndef KSA_DISPLAY_STATE_STOP_H
#define KSA_DISPLAY_STATE_STOP_H

#import <Foundation/Foundation.h>

@interface KSADisplayStateStop : NSObject

+ (instancetype)sharedInstance;

/// Registers the Darwin notifications and stops a running alert on any display/lock
/// transition. Safe to call once; further calls are ignored.
- (void)start;

@end

#endif
