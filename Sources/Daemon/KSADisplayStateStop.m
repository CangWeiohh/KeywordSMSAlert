//
//  KSADisplayStateStop.m
//
//  Fallback stop source: "the user pressed the power button" is inferred from the
//  display / lock state, because imagent (where this runs) has no HID entitlement and
//  this build deliberately starts no second process.
//
//  The hard part is that the *same* transitions are produced by the system itself:
//
//    * the incoming SMS notification lights the lock screen, and that notification
//      wake times out a few seconds later -> 显示 熄屏 -> 亮屏 -> 熄屏
//    * auto-lock / auto-dim                               -> 显示 亮屏 -> 熄屏
//    * raise to wake                                      -> 显示 熄屏 -> 亮屏
//
//  Treating any of those as "power button pressed" makes the alert kill itself - which
//  is exactly what happened when the notification wake timed out.
//
//  Rules used here (each one is deliberate):
//
//    1. display OFF -> ON, more than `kKSAScreenWakeGrace` after the alert started:
//       a power press on a sleeping phone  -> STOP. A wake inside the grace window is
//       the incoming notification, and it is remembered so that rule 3 can pair it up.
//    2. lock state becomes "locked": a real lock action -> STOP. (A notification wake
//       never changes the lock state, so this cannot be a false positive from one.)
//    3. display ON -> OFF:
//         a. the wake we ignored in rule 1 for THIS alert timed out -> IGNORE.
//         b. the device is currently locked -> IGNORE: this is the notification wake
//            timing out (or a first power press on the lock screen, which is
//            indistinguishable); the alert keeps going and the next press stops it.
//         c. otherwise (the user was actively using an unlocked phone) -> STOP.
//
//  Net effect: the alert survives the notification's screen wake *and* its timeout.
//  To stop it: press power while the screen is dark (wakes it -> STOP), or press power
//  while using an unlocked phone (locks it -> STOP). If the screen happens to be
//  showing the lock screen, the first press is treated as the notification timing out
//  and a second press stops the alert.
//

#import "KSADisplayStateStop.h"
#import "KSARuntimeStatus.h"
#import "KSAAlertManager.h"
#import "KSACommon.h"
#import "KSALog.h"

#import <notify.h>
#import <math.h>

/// A screen wake inside this window after the alert started is attributed to the
/// incoming SMS notification rather than to the power button.
static const NSTimeInterval kKSAScreenWakeGrace = 4.0;

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

    /// Alert start time for which rule 1 ignored a notification wake (0 = none), so
    /// rule 3a can recognise that wake timing out and leave the alert alone.
    NSTimeInterval _notificationWakeAlertStart;
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

    // The lock state is needed for rule 3b, and a notification wake produces no lock
    // state change at all - so read it once here instead of waiting for a callback.
    uint64_t currentLockState = UINT64_MAX;
    if (lockState == NOTIFY_STATUS_OK && notify_get_state(_lockToken, &currentLockState) == NOTIFY_STATUS_OK) {
        _haveLockState = YES;
        _lastLockState = currentLockState;
        _locked = (currentLockState == 1);
    }

    BOOL displayOK = (displayStatus == NOTIFY_STATUS_OK);
    BOOL lockOK = (lockState == NOTIFY_STATUS_OK);

    KSARuntimeStatusUpdate(@{
        @"FallbackStopActive": @(displayOK || lockOK),
        @"FallbackDisplayNotification": @(displayOK),
        @"FallbackLockNotification": @(lockOK),
        @"FallbackInitialLocked": @(_locked)
    });

    KSAInfo(@"power-button stop source ready (displayStatus=%d, lockstate=%d, locked=%d)",
            displayOK, lockOK, _locked);
}

- (void)ksa_displayStateChanged:(uint64_t)state
{
    // The first callback after registration may simply report the current state; only
    // a real transition counts.
    if (!_haveDisplayState) {
        _haveDisplayState = YES;
        _lastDisplayState = state;
        KSADebug(@"display state baseline = %llu (locked=%d)", (unsigned long long)state, _locked);
        return;
    }
    if (state == _lastDisplayState) {
        return;
    }
    _lastDisplayState = state;

    NSTimeInterval startedAt = [KSAAlertManager sharedInstance].lastAlertStartedAt;
    NSTimeInterval sinceStart = startedAt > 0 ? (KSANow() - startedAt) : -1;

    if (state == 1) {
        // ---- rule 1: screen turned on -------------------------------------------
        if (sinceStart >= 0 && sinceStart < kKSAScreenWakeGrace) {
            _notificationWakeAlertStart = startedAt;
            KSAInfo(@"screen woke %.1fs after the alert started - that is the incoming "
                    @"notification, alert continues", sinceStart);
            return;
        }
        [self ksa_stopIfAlertingWithReason:@"screen turned on (power button on a sleeping phone)"];
        return;
    }

    // ---- rule 3: screen turned off ----------------------------------------------
    if (_notificationWakeAlertStart > 0 && startedAt > 0 &&
        fabs(_notificationWakeAlertStart - startedAt) < 0.001) {
        KSAInfo(@"screen went dark after the notification wake - alert continues "
                @"(press power again to stop it)");
        _notificationWakeAlertStart = 0;
        return;
    }
    if (_locked) {
        KSAInfo(@"screen turned off while the device is locked - treating it as the "
                @"notification wake timing out, alert continues (press power again to stop it)");
        return;
    }
    [self ksa_stopIfAlertingWithReason:@"screen turned off (power button)"];
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

    if (state != 1) {
        return;   // unlocked: nothing to stop
    }

    // ---- rule 2: a real lock action --------------------------------------------
    [self ksa_stopIfAlertingWithReason:@"device locked (power button)"];
}

- (void)ksa_stopIfAlertingWithReason:(NSString *)reason
{
    if (![[KSAAlertManager sharedInstance] isAlerting]) {
        KSADebug(@"%@ while no alert is running (nothing to stop)", reason);
        return;
    }
    KSAInfo(@"stopping alert via power-button stop source (%@)", reason);
    [[KSAAlertManager sharedInstance] stopAlertWithReason:
     [NSString stringWithFormat:@"%@", reason]];
}

@end
