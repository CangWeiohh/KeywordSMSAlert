//
//  KSADisplayStateStop.m
//
//  Lock-state based stop source - the SAFE fallback used alongside the HID power-button
//  observer (see KSAHIDPowerButton).
//
//  WHY THERE ARE NO DISPLAY-STATE RULES ANY MORE
//
//  Earlier versions inferred "the power button was pressed" from the display turning on
//  or off. That cannot be made correct: the display is woken and blanked by many things
//  that have nothing to do with the button:
//
//    * the incoming SMS notification lights the lock screen   (熄屏 -> 亮屏)
//    * that notification wake times out a few seconds later   (亮屏 -> 熄屏)
//    * a tap on the screen (tap to wake)                      (熄屏 -> 亮屏)
//    * raise to wake / picking the phone up                   (熄屏 -> 亮屏)
//    * auto-dim / auto-lock                                   (亮屏 -> 熄屏)
//
//  Every attempt to "fix" one of those only exposed the next one: the alert was first
//  killed by the notification wake, then by the notification timing out, then by the
//  user tapping the screen. Display state is therefore now recorded for diagnostics only
//  and NEVER stops an alert.
//
//  What remains is the lock state, which none of those incidental events change:
//
//    * 未锁定 -> 已锁定 : the user locked the phone (power press while using it, or
//                         auto-lock). A notification or a tap never locks it.
//    * 已锁定 -> 未锁定 : the user actually unlocked it (passcode / Face ID), i.e. they
//                         are looking at the phone and have seen the reminder.
//
//  Both are deliberate user actions, so neither can be triggered by a notification, a
//  tap on the lock screen or raise to wake.
//

#import "KSADisplayStateStop.h"
#import "KSARuntimeStatus.h"
#import "KSAAlertManager.h"
#import "KSACommon.h"
#import "KSALog.h"

#import <notify.h>

@implementation KSADisplayStateStop
{
    BOOL _started;
    int _displayToken;
    int _lockToken;
    BOOL _haveDisplayState;
    uint64_t _lastDisplayState;
    BOOL _haveLockState;
    uint64_t _lastLockState;
    BOOL _locked;
    NSUInteger _displayTransitions;
}

+ (instancetype)sharedInstance
{
    static KSADisplayStateStop *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KSADisplayStateStop alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _displayToken = -1;
        _lockToken = -1;
    }
    return self;
}

- (void)start
{
    if (_started) {
        return;
    }
    _started = YES;

    uint32_t displayStatus = notify_register_dispatch("com.apple.iokit.hid.displayStatus",
                                                      &_displayToken,
                                                      dispatch_get_main_queue(),
                                                      ^(int token) {
        uint64_t state = UINT64_MAX;
        notify_get_state(token, &state);
        [self ksa_displayStateChanged:state];
    });

    uint32_t lockState = notify_register_dispatch("com.apple.springboard.lockstate",
                                                  &_lockToken,
                                                  dispatch_get_main_queue(),
                                                  ^(int token) {
        uint64_t state = UINT64_MAX;
        notify_get_state(token, &state);
        [self ksa_lockStateChanged:state];
    });

    uint64_t currentLockState = UINT64_MAX;
    if (lockState == NOTIFY_STATUS_OK && notify_get_state(_lockToken, &currentLockState) == NOTIFY_STATUS_OK) {
        _haveLockState = YES;
        _lastLockState = currentLockState;
        _locked = (currentLockState == 1);
    }

    BOOL displayOK = (displayStatus == NOTIFY_STATUS_OK);
    BOOL lockOK = (lockState == NOTIFY_STATUS_OK);

    KSARuntimeStatusUpdate(@{
        @"LockStopActive": @(lockOK),
        @"FallbackDisplayNotification": @(displayOK),
        @"FallbackLockNotification": @(lockOK),
        @"FallbackInitialLocked": @(_locked)
    });

    KSAInfo(@"lock-state stop source ready (displayStatus=%d, lockstate=%d, locked=%d) - "
            @"display changes never stop an alert", displayOK, lockOK, _locked);
}

/// Diagnostics only: display transitions also come from notifications, tap-to-wake,
/// raise-to-wake and auto-dim, so they must never stop an alert.
- (void)ksa_displayStateChanged:(uint64_t)state
{
    if (!_haveDisplayState) {
        _haveDisplayState = YES;
        _lastDisplayState = state;
        KSADebug(@"display baseline = %llu (locked=%d)", (unsigned long long)state, _locked);
        return;
    }
    if (state == _lastDisplayState) {
        return;
    }
    _lastDisplayState = state;
    _displayTransitions++;

    NSTimeInterval startedAt = [KSAAlertManager sharedInstance].lastAlertStartedAt;
    NSTimeInterval sinceStart = startedAt > 0 ? (KSANow() - startedAt) : -1;
    KSAInfo(@"display %@ (%.1fs into the alert, locked=%d) - ignored, only lock changes stop an alert",
            state == 1 ? @"turned on" : @"turned off", sinceStart, _locked);

    KSARuntimeStatusUpdate(@{
        @"LastDisplayTransitionAt": @(KSANow()),
        @"DisplayTransitions": @(_displayTransitions)
    });
}

- (void)ksa_lockStateChanged:(uint64_t)state
{
    if (!_haveLockState) {
        _haveLockState = YES;
        _lastLockState = state;
        _locked = (state == 1);
        return;
    }
    if (state == _lastLockState) {
        return;
    }
    _lastLockState = state;
    _locked = (state == 1);

    if (state == 1) {
        [self ksa_stopIfAlertingWithReason:@"phone locked by the user"];
    } else {
        [self ksa_stopIfAlertingWithReason:@"phone unlocked - the user has seen it"];
    }
}

- (void)ksa_stopIfAlertingWithReason:(NSString *)reason
{
    if (![[KSAAlertManager sharedInstance] isAlerting]) {
        KSADebug(@"%@ while no alert is running (nothing to stop)", reason);
        return;
    }
    KSAInfo(@"stopping alert (%@)", reason);
    [[KSAAlertManager sharedInstance] stopAlertWithReason:reason];
}

@end
