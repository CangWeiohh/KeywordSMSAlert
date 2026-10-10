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
//  Semantics (the system produces the same transitions as the power button, so each
//  case is handled explicitly):
//
//    * display OFF -> ON well after the alert started  -> STOP (power press on a
//      sleeping phone). A wake right after the alert started is the incoming SMS
//      notification and is ignored - and remembered.
//    * lock state becomes locked                       -> STOP (a real lock action; a
//      notification wake never changes the lock state).
//    * display ON -> OFF                               -> STOP only when the user was
//      using an unlocked phone. If it follows the notification wake, or the device is
//      locked, it is the notification's own timeout / auto-dim and the alert keeps
//      running (press power again to stop it).
//
//  Before this, "display ON -> OFF" always stopped the alert, so the incoming SMS
//  notification woke the lock screen and a few seconds later its timeout killed the
//  alert - the vibration and the sound stopped together.
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
