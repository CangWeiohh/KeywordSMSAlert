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
//  How it is done:
//    * the verified high level entry point
//      -[SBLockScreenManager lockUIFromSource:withOptions:] is hooked in
//      KeywordSMSAlert.xm (the original implementation always runs first, so
//      locking keeps working);
//    * additionally, at runtime, SpringBoard's own hardware-button action methods
//      are *discovered* (class_copyMethodList) and hooked by pattern, so a press
//      is caught even when the screen is off (press-to-wake does not go through
//      lockUIFromSource:). Nothing is guessed at compile time: only selectors that
//      actually exist at runtime are hooked, and every decision is logged.
//
//  No polling of any kind is used anywhere in this file.
//

#ifndef KSA_POWER_BUTTON_H
#define KSA_POWER_BUTTON_H

#import <Foundation/Foundation.h>

@interface KSAPowerButton : NSObject

+ (instancetype)sharedInstance;

/// Selectors that are already hooked (with exact signatures) by the Logos groups in
/// KeywordSMSAlertAlert.xm. The discovery pass will not hook them a second time.
/// Call before -startInSpringBoard.
- (void)skipSelectorNames:(NSArray<NSString *> *)selectorNames;

/// Called from the tweak constructor inside SpringBoard. Installs the discovered
/// hardware-button watchers and logs what was found.
- (void)startInSpringBoard;

/// Hook entry point: a physical button event was observed. Thread safe.
- (void)noteEvent:(NSString *)eventName;

/// Debug helper: logs the button/backlight related selectors that exist in the
/// running SpringBoard. Only emitted while DebugEnabled = 1.
- (void)logDiagnostics;

/// Summary of the watchers that were installed (for the README / log).
- (NSString *)diagnostics;

@end

#endif /* KSA_POWER_BUTTON_H */
