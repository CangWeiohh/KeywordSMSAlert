//
//  KSAPowerButton.h
//  KeywordSMSAlert
//
//  Side/Power button watcher (SpringBoard only).
//
//  Requirement: while our alert is playing, a press of the physical side/power
//  button must stop it immediately - without polling, without taking over the
//  button, and without breaking lock/wake.
//
//  How it is done (1.1.3):
//    * four verified methods are hooked with exact signatures in
//      KeywordSMSAlertAlert.xm - SBLockScreenManager -lockUIFromSource:...,
//      SBSleepWakeHardwareButtonInteraction -consumeInitialPressDown,
//      SBLockHardwareButtonActions -performInitialButtonDownActions and
//      SBLockHardwareButton -buttonDown:;
//    * all four run the original implementation and keep its result, so lock /
//      wake / SOS / Siri behaviour is untouched;
//    * the hooks are installed LAZILY (first alert), never at dylib load time -
//      see KSAHookInstaller.h;
//    * this class only turns "a button event happened" into "stop the alert",
//      which is a no-op unless an alert is actually playing.
//
//  No polling and no runtime discovery/hooking of arbitrary selectors is used
//  anywhere in this file.
//

#ifndef KSA_POWER_BUTTON_H
#define KSA_POWER_BUTTON_H

#import <Foundation/Foundation.h>

@interface KSAPowerButton : NSObject

+ (instancetype)sharedInstance;

/// Called from the tweak constructor inside SpringBoard, AFTER the process check.
/// Read-only: logs which button/lock/backlight selectors this build exposes when
/// DebugEnabled = 1, and does it off the main thread. It never installs a hook.
- (void)noteSpringBoardReady;

/// Bookkeeping for the lazily installed hooks (KSAHookInstaller.h).
- (void)noteWatcherInstalled:(NSString *)watcher;

/// Hook entry point: a physical button event was observed. Thread safe.
- (void)noteEvent:(NSString *)eventName;

/// Debug helper: logs the button/backlight related selectors that exist in the
/// running SpringBoard. Only emitted while DebugEnabled = 1.
- (void)logDiagnostics;

/// Summary of the watchers that were installed (for the README / log).
- (NSString *)diagnostics;

@end

#endif /* KSA_POWER_BUTTON_H */
