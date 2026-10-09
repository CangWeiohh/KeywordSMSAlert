//
//  KSADisplayStateStop.m
//

#import "KSADisplayStateStop.h"
#import "KSARuntimeStatus.h"
#import "KSAAlertManager.h"
#import "KSALog.h"

#import <notify.h>

@implementation KSADisplayStateStop
{
    BOOL _started;
    int _displayToken;
    int _lockToken;
    BOOL _haveDisplayState;
    uint64_t _lastDisplayState;
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

    [self ksa_stopIfAlertingWithReason:
     [NSString stringWithFormat:@"display %@", state == 1 ? @"turned on" : @"turned off"]];
}

- (void)ksa_lockStateChanged:(uint64_t)state
{
    if (state != 1) {
        return;
    }
    [self ksa_stopIfAlertingWithReason:@"device locked"];
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
