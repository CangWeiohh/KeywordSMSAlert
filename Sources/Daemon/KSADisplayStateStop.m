//
//  KSADisplayStateStop.m
//

#import "KSADisplayStateStop.h"
#import "KSARuntimeStatus.h"
#import "KSAAlertManager.h"
#import "KSACommon.h"
#import "KSALog.h"

#import <notify.h>

/// A screen wake that happens right after an alert starts is almost always the
/// incoming SMS notification lighting the lock screen - not the user pressing the
/// power button. Wakes inside this window are therefore ignored; the power button can
/// still stop the alert by turning the screen OFF (which is unambiguous), so a user
/// who presses the button while the screen is dark only has to press it twice.
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

    BOOL displayOK = (displayStatus == NOTIFY_STATUS_OK);
    BOOL lockOK = (lockState == NOTIFY_STATUS_OK);

    KSARuntimeStatusUpdate(@{
        @"FallbackStopActive": @(displayOK || lockOK),
        @"FallbackDisplayNotification": @(displayOK),
        @"FallbackLockNotification": @(lockOK)
    });

    KSAInfo(@"fallback stop source active (displayStatus=%d, lockstate=%d) - "
            @"used because the HID power-button observer is unavailable",
            displayOK, lockOK);
}

- (void)ksa_displayStateChanged:(uint64_t)state
{
    // The first callback after registration may simply report the current state; only
    // a real transition counts as a power-button press.
    if (!_haveDisplayState) {
        _haveDisplayState = YES;
        _lastDisplayState = state;
        KSADebug(@"display state baseline = %llu", (unsigned long long)state);
        return;
    }
    if (state == _lastDisplayState) {
        return;
    }
    _lastDisplayState = state;

    if (state == 1) {
        // Screen turned ON. This is either the user pressing the power button on a
        // sleeping phone, or the SMS notification waking the lock screen. Ignore the
        // notification case (a wake close to the alert start).
        NSTimeInterval startedAt = [KSAAlertManager sharedInstance].lastAlertStartedAt;
        NSTimeInterval sinceStart = startedAt > 0 ? (KSANow() - startedAt) : -1;
        if (sinceStart >= 0 && sinceStart < kKSAScreenWakeGrace) {
            KSAInfo(@"screen turned on %.1fs after the alert started - treating it as the "
                    @"incoming notification, alert continues (press power again to stop)",
                    sinceStart);
            return;
        }
        [self ksa_stopIfAlertingWithReason:@"screen turned on (power button)"];
        return;
    }

    // Screen turned OFF: locking is unambiguous, and it is what a power press does
    // while the screen is already on.
    [self ksa_stopIfAlertingWithReason:@"screen turned off (power button)"];
}

- (void)ksa_lockStateChanged:(uint64_t)state
{
    if (!_haveLockState) {
        _haveLockState = YES;
        _lastLockState = state;
        return;
    }
    if (state == _lastLockState) {
        return;
    }
    _lastLockState = state;

    if (state != 1) {
        return;   // unlocked
    }
    [self ksa_stopIfAlertingWithReason:@"device locked (power button)"];
}

- (void)ksa_stopIfAlertingWithReason:(NSString *)reason
{
    if (![[KSAAlertManager sharedInstance] isAlerting]) {
        KSADebug(@"%@ while no alert is running (nothing to stop)", reason);
        return;
    }
    KSAInfo(@"stopping alert via fallback stop source (%@)", reason);
    [[KSAAlertManager sharedInstance] stopAlertWithReason:
     [NSString stringWithFormat:@"%@ (fallback)", reason]];
}

@end
