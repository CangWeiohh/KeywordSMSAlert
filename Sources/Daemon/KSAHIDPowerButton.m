//
//  KSAHIDPowerButton.m
//
//  Observes the physical power button from inside imagent - no hooks, no second process,
//  no SpringBoard injection.
//
//  Verified building blocks:
//    * IOHID keyboard event type = 3
//    * fields: UsagePage=0x30000, Usage=0x30001, Down=0x30002
//    * candidate usages (KSAHIDEventMatcher.c): Consumer/Power 0x0C/0x30,
//      AppleVendor/Screensave 0xFF01/0x0B (how the iPhone lock button is usually
//      reported) and Keyboard/Power 0x07/0x66.
//
//  Measured on device:
//    * 1.2.7: IOHIDEventSystemClientCreate SUCCEEDS inside imagent, so creating the client
//      is NOT the problem.
//    * 1.2.8 (the first version that actually counted events): ZERO events ever arrived,
//      using IOHIDEventSystemClientSetDispatchQueue.
//
//  This file therefore answers the remaining question in ONE install:
//    * how many HID services the process can even see (0 => the sandbox blocks the HID
//      event system for imagent and no delivery path can ever work),
//    * which delivery strategy actually receives events: main run loop, dispatch queue, or
//      a dedicated thread with its own run loop.
//  Keyboard events are decoded and the last (page, usage, down) is published, so the real
//  usage of this device's button can be read from Settings without a terminal.
//
//  The client is observation-only: it never dispatches, consumes or mutates an HID event,
//  so normal sleep/wake/lock/SOS/Siri handling stays untouched.
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
typedef CFArrayRef (*KSACopyServicesFn)(KSAIOHIDEventSystemClientRef client);

static NSString *const kKSAStrategyMainRunLoop   = @"main-runloop";
static NSString *const kKSAStrategyDispatchQueue = @"dispatch-queue";
static NSString *const kKSAStrategyThreadRunLoop = @"thread-runloop";

static const uint32_t kKSAIOHIDEventTypeKeyboard = 3;
static const uint32_t kKSAKeyboardUsagePageField = 0x00030000;
static const uint32_t kKSAKeyboardUsageField     = 0x00030001;
static const uint32_t kKSAKeyboardDownField      = 0x00030002;

@interface KSAHIDPowerButton ()
@property (atomic, readwrite, getter=isAvailable) BOOL available;
- (void)ksa_fail:(NSString *)reason;
- (void)ksa_startStrategy:(NSString *)strategy;
- (void)ksa_handleEvent:(KSAIOHIDEventRef)event strategy:(NSString *)strategy;
- (void)ksa_publishCounters;
@end

@implementation KSAHIDPowerButton
{
    void *_iokitHandle;
    KSAClientCreateFn _createClient;
    KSARegisterCallbackFn _registerCallback;
    KSASetDispatchQueueFn _setDispatchQueue;
    KSAScheduleFn _schedule;
    KSAGetTypeFn _getType;
    KSAGetIntegerValueFn _getIntegerValue;

    NSMutableArray *_clients;
    NSMutableDictionary<NSString *, NSNumber *> *_strategyEventCounts;
    NSInteger _servicesVisible;

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
    NSLock *_lock;
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

- (instancetype)init
{
    self = [super init];
    if (self) {
        _clients = [NSMutableArray array];
        _strategyEventCounts = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
        _servicesVisible = -3;   // not probed yet
    }
    return self;
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
    NSString *strategy = refcon ? (__bridge NSString *)refcon : @"?";
    [observer ksa_handleEvent:event strategy:strategy];
}

#pragma mark - Start

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

    _createClient = (KSAClientCreateFn)dlsym(_iokitHandle, "IOHIDEventSystemClientCreate");
    _schedule = (KSAScheduleFn)dlsym(_iokitHandle, "IOHIDEventSystemClientScheduleWithRunLoop");
    _setDispatchQueue = (KSASetDispatchQueueFn)dlsym(_iokitHandle,
                                                     "IOHIDEventSystemClientSetDispatchQueue");
    _registerCallback = (KSARegisterCallbackFn)dlsym(
        _iokitHandle, "IOHIDEventSystemClientRegisterEventCallback");
    KSACopyServicesFn copyServices = (KSACopyServicesFn)dlsym(
        _iokitHandle, "IOHIDEventSystemClientCopyServices");
    _getType = (KSAGetTypeFn)dlsym(_iokitHandle, "IOHIDEventGetType");
    _getIntegerValue = (KSAGetIntegerValueFn)dlsym(_iokitHandle,
                                                   "IOHIDEventGetIntegerValue");

    if (_createClient == NULL || _registerCallback == NULL ||
        _getType == NULL || _getIntegerValue == NULL) {
        [self ksa_fail:@"required IOHID symbols are missing"];
        return;
    }

    // How many HID services can this process even see? Zero means the sandbox blocks the
    // HID event system for imagent and no delivery strategy can ever help.
    KSAIOHIDEventSystemClientRef probe = _createClient(kCFAllocatorDefault);
    if (probe != NULL) {
        if (copyServices != NULL) {
            CFArrayRef services = copyServices(probe);
            _servicesVisible = (services != NULL) ? (NSInteger)CFArrayGetCount(services) : -1;
            if (services != NULL) {
                CFRelease(services);
            }
        } else {
            _servicesVisible = -2;   // symbol missing
        }
        CFRelease(probe);
    }

    self.available = YES;
    KSARuntimeStatusUpdate(@{
        @"HIDAvailable": @YES,
        @"HIDDelivering": @NO,
        @"HIDServices": @(_servicesVisible),
        @"HIDDelivery": kKSAStrategyMainRunLoop,
        @"HIDStatus": [NSString stringWithFormat:@"client created, %ld HID service(s) visible",
                       (long)_servicesVisible]
    });
    KSAInfo(@"HID observer: client created, %ld HID service(s) visible; trying delivery "
            @"strategies (main run loop first)", (long)_servicesVisible);

    [self ksa_startStrategy:kKSAStrategyMainRunLoop];

    // If nothing arrives, try the other delivery paths: one install then tells us which
    // (if any) imagent is allowed to use.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || self->_eventsSeen > 0) {
            return;
        }
        [self ksa_startStrategy:kKSAStrategyDispatchQueue];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || self->_eventsSeen > 0) {
            return;
        }
        [self ksa_startStrategy:kKSAStrategyThreadRunLoop];
    });
}

/// Starts one delivery strategy with its own client. The strategy name travels through the
/// callback's refcon, so every event can be attributed to the path that delivered it.
- (void)ksa_startStrategy:(NSString *)strategy
{
    if (_createClient == NULL || strategy.length == 0) {
        return;
    }

    KSAIOHIDEventSystemClientRef client = _createClient(kCFAllocatorDefault);
    if (client == NULL) {
        KSAInfo(@"HID strategy %@: client creation failed", strategy);
        return;
    }

    if ([strategy isEqualToString:kKSAStrategyDispatchQueue]) {
        if (_setDispatchQueue == NULL) {
            CFRelease(client);
            KSAInfo(@"HID strategy %@ unavailable (symbol missing)", strategy);
            return;
        }
        static dispatch_queue_t queue = NULL;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            queue = dispatch_queue_create("com.keyword.smsalert.hid", DISPATCH_QUEUE_SERIAL);
        });
        _setDispatchQueue(client, queue);
    } else if ([strategy isEqualToString:kKSAStrategyThreadRunLoop]) {
        if (_schedule == NULL) {
            CFRelease(client);
            return;
        }
        KSAScheduleFn schedule = _schedule;
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            schedule(client, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            KSAInfo(@"HID client scheduled on a dedicated run loop thread");
            CFRunLoopRun();   // never returns
        }];
        thread.name = @"com.keyword.smsalert.hid-runloop";
        thread.qualityOfService = NSQualityOfServiceUtility;
        [thread start];
    } else {
        if (_schedule == NULL) {
            CFRelease(client);
            return;
        }
        _schedule(client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    }

    _registerCallback(client, KSAHIDEventCallback,
                      (__bridge void *)self,
                      (__bridge void *)strategy);
    [_clients addObject:(__bridge id)client];
    CFRelease(client);

    KSAInfo(@"HID strategy %@ started", strategy);
    KSARuntimeStatusUpdate(@{ @"HIDDelivery": strategy });
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

#pragma mark - Events

- (void)ksa_publishCounters
{
    NSMutableDictionary *status = [NSMutableDictionary dictionaryWithDictionary:@{
        @"HIDEventsSeen": @(_eventsSeen),
        @"HIDKeyboardEvents": @(_keyboardEvents),
        @"HIDPowerHits": @(_powerHits),
        @"HIDServices": @(_servicesVisible)
    }];
    if (_haveKeyboardEvent) {
        status[@"HIDLastPage"] = @(_lastKeyboardPage);
        status[@"HIDLastUsage"] = @(_lastKeyboardUsage);
        status[@"HIDLastDown"] = @(_lastKeyboardDown);
    }
    if (_strategyEventCounts.count > 0) {
        status[@"HIDStrategyCounts"] = [_strategyEventCounts description];
    }
    KSARuntimeStatusUpdate(status);
}

- (void)ksa_handleEvent:(KSAIOHIDEventRef)event strategy:(NSString *)strategy
{
    // Any event at all proves the client is really being fed - which a successful
    // IOHIDEventSystemClientCreate does NOT prove.
    [_lock lock];
    _eventsSeen++;
    NSUInteger strategyCount = [_strategyEventCounts[strategy] unsignedIntegerValue] + 1;
    _strategyEventCounts[strategy] = @(strategyCount);
    BOOL firstEvent = (_eventsSeen == 1);
    NSUInteger total = _eventsSeen;
    if (firstEvent) {
        _delivery = strategy;
    }
    [_lock unlock];

    if (firstEvent) {
        KSARuntimeStatusUpdate(@{
            @"HIDDelivering": @YES,
            @"HIDDelivery": strategy,
            @"HIDStatus": [NSString stringWithFormat:@"receiving events via %@", strategy]
        });
        KSAInfo(@"HID events are arriving via %@ (%ld HID services visible)",
                strategy, (long)_servicesVisible);
    }

    uint32_t type = _getType(event);
    if (type != kKSAIOHIDEventTypeKeyboard) {
        if (firstEvent || (total % 500) == 0) {
            [self ksa_publishCounters];
        }
        return;
    }

    int64_t page = _getIntegerValue(event, kKSAKeyboardUsagePageField);
    int64_t usage = _getIntegerValue(event, kKSAKeyboardUsageField);
    int64_t down = _getIntegerValue(event, kKSAKeyboardDownField);

    [_lock lock];
    _keyboardEvents++;
    _lastKeyboardPage = page;
    _lastKeyboardUsage = usage;
    _lastKeyboardDown = down;
    _haveKeyboardEvent = YES;
    [_lock unlock];

    BOOL matches = KSAHIDEventIsPowerButtonDown(type, page, usage, down);
    KSAInfo(@"HID keyboard event via %@: page=0x%llX usage=0x%llX down=%lld (power match: %d)",
            strategy, (unsigned long long)page, (unsigned long long)usage,
            (long long)down, matches);
    [self ksa_publishCounters];

    if (!matches) {
        return;
    }

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    [_lock lock];
    BOOL tooSoon = (now - _lastPowerDownTime) < 0.25;
    if (!tooSoon) {
        _lastPowerDownTime = now;
        _powerHits++;
    }
    NSUInteger hits = _powerHits;
    [_lock unlock];
    if (tooSoon) {
        return;
    }

    KSARuntimeStatusUpdate(@{
        @"LastPowerButtonAt": @(now),
        @"LastPowerButtonPage": @(page),
        @"LastPowerButtonUsage": @(usage),
        @"HIDPowerHits": @(hits)
    });

    if (![[KSAAlertManager sharedInstance] isAlerting]) {
        KSADebug(@"physical power button observed while no alert is running");
        return;
    }

    KSAInfo(@"physical power button observed - stopping the alert");
    [[KSAAlertManager sharedInstance] stopAlertWithReason:@"physical power button (IOHID)"];
}

@end
