//
//  KSAHIDPowerButton.m
//
//  Verified building blocks:
//    * IOHID keyboard event type = 3
//    * fields: UsagePage=0x30000, Usage=0x30001, Down=0x30002
//    * Consumer page 0x0C, usage 0x30 = Power
//
//  The client is observation-only: it never dispatches, consumes or mutates an HID
//  event, so the system's normal sleep/wake/SOS/Siri handling stays untouched.
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
@end

@implementation KSAHIDPowerButton
{
    void *_iokitHandle;
    KSAIOHIDEventSystemClientRef _client;
    KSAGetTypeFn _getType;
    KSAGetIntegerValueFn _getIntegerValue;
    NSTimeInterval _lastPowerDownTime;
    BOOL _started;
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
    KSAScheduleFn schedule = (KSAScheduleFn)dlsym(_iokitHandle,
                                                   "IOHIDEventSystemClientScheduleWithRunLoop");
    KSARegisterCallbackFn registerCallback = (KSARegisterCallbackFn)dlsym(
        _iokitHandle, "IOHIDEventSystemClientRegisterEventCallback");
    _getType = (KSAGetTypeFn)dlsym(_iokitHandle, "IOHIDEventGetType");
    _getIntegerValue = (KSAGetIntegerValueFn)dlsym(_iokitHandle,
                                                   "IOHIDEventGetIntegerValue");

    if (createClient == NULL || schedule == NULL || registerCallback == NULL ||
        _getType == NULL || _getIntegerValue == NULL) {
        [self ksa_fail:@"required IOHID symbols are missing"];
        return;
    }

    _client = createClient(kCFAllocatorDefault);
    if (_client == NULL) {
        [self ksa_fail:@"IOHIDEventSystemClientCreate returned NULL"];
        return;
    }

    schedule(_client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    registerCallback(_client,
                     KSAHIDEventCallback,
                     (__bridge void *)self,
                     NULL);

    self.available = YES;
    KSARuntimeStatusUpdate(@{
        @"HIDAvailable": @YES,
        @"HIDStatus": @"ready"
    });
    KSAInfo(@"standalone HID power-button observer ready (Consumer 0x0C / Power 0x30)");
}

- (void)ksa_fail:(NSString *)reason
{
    self.available = NO;
    KSARuntimeStatusUpdate(@{
        @"HIDAvailable": @NO,
        @"HIDStatus": reason ?: @"unknown error"
    });
    KSAInfo(@"standalone HID observer unavailable: %@", reason ?: @"unknown error");
}

- (void)ksa_handleEvent:(KSAIOHIDEventRef)event
{
    uint32_t type = _getType(event);
    if (type != kKSAIOHIDEventTypeKeyboard) {
        return;
    }

    int64_t page = _getIntegerValue(event, kKSAKeyboardUsagePageField);
    int64_t usage = _getIntegerValue(event, kKSAKeyboardUsageField);
    int64_t down = _getIntegerValue(event, kKSAKeyboardDownField);
    if (!KSAHIDEventIsPowerButtonDown(type, page, usage, down)) {
        return;
    }

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if ((now - _lastPowerDownTime) < 0.25) {
        return;
    }
    _lastPowerDownTime = now;

    KSARuntimeStatusUpdate(@{
        @"LastPowerButtonAt": @(now),
        @"LastPowerButtonPage": @(page),
        @"LastPowerButtonUsage": @(usage)
    });

    if (![[KSAAlertManager sharedInstance] isAlerting]) {
        KSADebug(@"physical power button observed while no alert is running");
        return;
    }

    KSAInfo(@"physical power button observed by standalone HID client - stopping alert");
    [[KSAAlertManager sharedInstance] stopAlertWithReason:@"physical power button (IOHID)"];
}

@end
