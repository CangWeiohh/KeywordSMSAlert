//
//  KSAHIDPowerButton.m
//
//  Observes the physical power button from inside imagent, without hooks, without a
//  second process and without a SpringBoard injection.
//
//  Verified building blocks:
//    * IOHID keyboard event type = 3
//    * fields: UsagePage=0x30000, Usage=0x30001, Down=0x30002
//    * candidate button usages (see KSAHIDEventMatcher.c): Consumer/Power 0x0C/0x30,
//      AppleVendor/Screensave 0xFF01/0x0B (how the iPhone lock button is usually
//      reported) and Keyboard/Power 0x07/0x66.
//
//  Measured on device (1.2.7): IOHIDEventSystemClientCreate SUCCEEDS inside imagent,
//  so the entitlement is not the blocker - but no event ever stopped the alert. The two
//  remaining suspects are fixed here:
//
//    1. delivery: 1.2.7 scheduled the client on imagent's *main* run loop, which is not
//       guaranteed to run kCFRunLoopDefaultMode at all. 1.2.8 prefers
//       IOHIDEventSystemClientSetDispatchQueue (no run loop involved) and otherwise uses
//       a dedicated thread with its own run loop.
//    2. matching: only Consumer/Power was accepted. Keyboard events are now decoded and
//       the last (page, usage, down) is published to the settings pane, so the real
//       usage of this device's button can be read without a terminal.
//
//  The client is observation-only: it never dispatches, consumes or mutates an HID
//  event, so normal sleep/wake/lock/SOS/Siri handling stays untouched.
//

#import "KSAHIDPowerButton.h"
#import "KSARuntimeStatus.h"
#import "KSAAlertManager.h"
#import "KSALog.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

#pragma mark - Minimal private IOKit declarations (resolved with dlsym)

typedef void *KSAIOHIDEventSystemClientRef;
typedef void *KSAIOHIDEventRef;
typedef void *KSAIOHIDServiceRef;
typedef uint32_t KSAIOHIDEventType;

typedef KSAIOHIDEventSystemClientRef (*KSAClientCreateFn)(CFAllocatorRef allocator);
typedef void (*KSAScheduleFn)(KSAIOHIDEventSystemClientRef client,
                              CFRunLoopRef runLoop,
                              CFStringRef mode);
typedef void (*KSASetDispatchQueueFn)(KSAIOHIDEventSystemClientRef client,
                                      dispatch_queue_t queue);
typedef void (*KSAEventCallbackFn)(void *target,
                                   void *refcon,
                                   KSAIOHIDServiceRef service,
                                   KSAIOHIDEventRef event);
typedef void (*KSARegisterCallbackFn)(KSAIOHIDEventSystemClientRef client,
                                      KSAEventCallbackFn callback,
                                      void *target,
                                      void *refcon);
typedef KSAIOHIDEventType (*KSAGetTypeFn)(KSAIOHIDEventRef event);
typedef int64_t (*KSAGetIntegerValueFn)(KSAIOHIDEventRef event, uint32_t field);

static const uint32_t kKSAIOHIDEventTypeKeyboard = 3;
static const uint32_t kKSAKeyboardUsagePageField = 0x00030000;
static const uint32_t kKSAKeyboardUsageField     = 0x00030001;
static const uint32_t kKSAKeyboardDownField      = 0x00030002;

@interface KSAHIDPowerButton ()
@property (atomic, readwrite, getter=isAvailable) BOOL available;
- (void)ksa_fail:(NSString *)reason;
- (void)ksa_handleEvent:(KSAIOHIDEventRef)event;
- (void)ksa_publishCounters;
@end

@implementation KSAHIDPowerButton
{
    void *_iokitHandle;
    KSAIOHIDEventSystemClientRef _client;
    KSAScheduleFn _schedule;
    KSAGetTypeFn _getType;
    KSAGetIntegerValueFn _getIntegerValue;
    NSTimeInterval _lastPowerDownTime;
    BOOL _started;
    NSUInteger _eventsSeen;
    NSUInteger _keyboardEvents;
    NSUInteger _powerHits;
    int64_t _lastKeyboardPage;
    int64_t _lastKeyboardUsage;
    int64_t _lastKeyboardDown;
    BOOL _haveKeyboardEvent;
    NSString *_delivery;
}

+ (instancetype)sharedInstance
{
    static KSAHIDPowerButton *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KSAHIDPowerButton alloc] init];
    });
    return instance;
}

static void KSAHIDEventCallback(void *target,
                                void *refcon,
                                KSAIOHIDServiceRef service,
                                KSAIOHIDEventRef event)
{
    KSAHIDPowerButton *observer = (__bridge KSAHIDPowerButton *)target;
    if (observer == nil || event == NULL) {
        return;
    }
    [observer ksa_handleEvent:event];
}

- (void)start
{
    if (_started) {
        return;
    }
    _started = YES;

    _iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                          RTLD_NOW | RTLD_LOCAL);
    if (_iokitHandle == NULL) {
        [self ksa_fail:@"IOKit could not be loaded"];
        return;
    }

    KSAClientCreateFn createClient = (KSAClientCreateFn)dlsym(_iokitHandle,
                                                               "IOHIDEventSystemClientCreate");
    _schedule = (KSAScheduleFn)dlsym(_iokitHandle,
                                     "IOHIDEventSystemClientScheduleWithRunLoop");
    KSASetDispatchQueueFn setDispatchQueue = (KSASetDispatchQueueFn)dlsym(
        _iokitHandle, "IOHIDEventSystemClientSetDispatchQueue");
    KSARegisterCallbackFn registerCallback = (KSARegisterCallbackFn)dlsym(
        _iokitHandle, "IOHIDEventSystemClientRegisterEventCallback");
    _getType = (KSAGetTypeFn)dlsym(_iokitHandle, "IOHIDEventGetType");
    _getIntegerValue = (KSAGetIntegerValueFn)dlsym(_iokitHandle,
                                                   "IOHIDEventGetIntegerValue");

    if (createClient == NULL || registerCallback == NULL ||
        _getType == NULL || _getIntegerValue == NULL) {
        [self ksa_fail:@"required IOHID symbols are missing"];
        return;
    }

    _client = createClient(kCFAllocatorDefault);
    if (_client == NULL) {
        [self ksa_fail:@"IOHIDEventSystemClientCreate returned NULL"];
        return;
    }

    if (setDispatchQueue != NULL) {
        // Preferred: no run loop involved at all.
        static dispatch_queue_t queue = NULL;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            queue = dispatch_queue_create("com.keyword.smsalert.hid", DISPATCH_QUEUE_SERIAL);
        });
        setDispatchQueue(_client, queue);
        _delivery = @"dispatch-queue";
    } else if (_schedule != NULL) {
        // Dedicated thread with its own run loop: relying on imagent's *main* run loop
        // was the flaw in 1.2.7 - nothing guarantees it runs kCFRunLoopDefaultMode.
        KSAScheduleFn schedule = _schedule;
        KSAIOHIDEventSystemClientRef client = _client;
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            schedule(client, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            KSAInfo(@"HID client scheduled on a dedicated run loop thread");
            CFRunLoopRun();   // never returns
        }];
        thread.name = @"com.keyword.smsalert.hid-runloop";
        thread.qualityOfService = NSQualityOfServiceUtility;
        [thread start];
        _delivery = @"dedicated-runloop-thread";
    } else {
        [self ksa_fail:@"no way to schedule the IOHID client"];
        return;
    }

    registerCallback(_client,
                     KSAHIDEventCallback,
                     (__bridge void *)self,
                     NULL);

    self.available = YES;
    KSARuntimeStatusUpdate(@{
        @"HIDAvailable": @YES,
        @"HIDDelivering": @NO,          // set to YES once an event really arrives
        @"HIDDelivery": _delivery ?: @"?",
        @"HIDStatus": @"client created, waiting for the first event"
    });
    KSAInfo(@"HID power-button observer registered (delivery=%@); the client is created "
            @"successfully, the open question is whether events arrive", _delivery);
}

- (void)ksa_fail:(NSString *)reason
{
    self.available = NO;
    KSARuntimeStatusUpdate(@{
        @"HIDAvailable": @NO,
        @"HIDStatus": reason ?: @"unknown error"
    });
    KSAInfo(@"HID power-button observer unavailable: %@", reason ?: @"unknown error");
}

- (void)ksa_publishCounters
{
    NSMutableDictionary *status = [NSMutableDictionary dictionaryWithDictionary:@{
        @"HIDEventsSeen": @(_eventsSeen),
        @"HIDKeyboardEvents": @(_keyboardEvents),
        @"HIDPowerHits": @(_powerHits)
    }];
    if (_haveKeyboardEvent) {
        status[@"HIDLastPage"] = @(_lastKeyboardPage);
        status[@"HIDLastUsage"] = @(_lastKeyboardUsage);
        status[@"HIDLastDown"] = @(_lastKeyboardDown);
    }
    KSARuntimeStatusUpdate(status);
}

- (void)ksa_handleEvent:(KSAIOHIDEventRef)event
{
    // Any event at all proves the client is really being fed - which a successful
    // IOHIDEventSystemClientCreate does NOT prove.
    _eventsSeen++;
    if (_eventsSeen == 1) {
        KSARuntimeStatusUpdate(@{
            @"HIDDelivering": @YES,
            @"HIDStatus": @"receiving events"
        });
        KSAInfo(@"HID client is delivering events (%@)", _delivery ?: @"?");
    }

    uint32_t type = _getType(event);
    if (type != kKSAIOHIDEventTypeKeyboard) {
        if ((_eventsSeen % 500) == 0) {
            [self ksa_publishCounters];
        }
        return;
    }

    int64_t page = _getIntegerValue(event, kKSAKeyboardUsagePageField);
    int64_t usage = _getIntegerValue(event, kKSAKeyboardUsageField);
    int64_t down = _getIntegerValue(event, kKSAKeyboardDownField);

    _keyboardEvents++;
    _lastKeyboardPage = page;
    _lastKeyboardUsage = usage;
    _lastKeyboardDown = down;
    _haveKeyboardEvent = YES;

    KSAInfo(@"HID keyboard event: page=0x%llX usage=0x%llX down=%lld (power button match: %d)",
            (unsigned long long)page, (unsigned long long)usage, (long long)down,
            KSAHIDEventIsPowerButtonDown(type, page, usage, down));
    [self ksa_publishCounters];

    if (!KSAHIDEventIsPowerButtonDown(type, page, usage, down)) {
        return;
    }

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if ((now - _lastPowerDownTime) < 0.25) {
        return;
    }
    _lastPowerDownTime = now;
    _powerHits++;

    KSARuntimeStatusUpdate(@{
        @"LastPowerButtonAt": @(now),
        @"LastPowerButtonPage": @(page),
        @"LastPowerButtonUsage": @(usage),
        @"HIDPowerHits": @(_powerHits)
    });

    if (![[KSAAlertManager sharedInstance] isAlerting]) {
        KSADebug(@"physical power button observed while no alert is running");
        return;
    }

    KSAInfo(@"physical power button observed - stopping the alert");
    [[KSAAlertManager sharedInstance] stopAlertWithReason:@"physical power button (IOHID)"];
}

@end
