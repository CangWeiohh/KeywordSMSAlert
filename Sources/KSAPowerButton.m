//
//  KSAPowerButton.m
//  KeywordSMSAlert
//

#import "KSAPowerButton.h"
#import "KSAAlertManager.h"
#import "KSACommon.h"
#import "KSAConfig.h"
#import "KSALog.h"

#import <objc/runtime.h>

/// Classes whose selectors are listed by the read-only diagnostics pass. Nothing in
/// this list is ever hooked here - the hooks live in KeywordSMSAlertAlert.xm and are
/// installed on demand. SBHIDButtonStateArbiter is deliberately absent (it belongs to
/// the camera shutter / volume arbiter path, not to the side/power button).
static NSString *const kKSADiagnosticClasses[] = {
    @"SBLockScreenManager",
    @"SBSleepWakeHardwareButtonInteraction",
    @"SBLockHardwareButtonActions",
    @"SBLockHardwareButton",
};
static const NSUInteger kKSADiagnosticClassCount =
    sizeof(kKSADiagnosticClasses) / sizeof(kKSADiagnosticClasses[0]);

static BOOL KSASelectorIsInteresting(NSString *selectorName)
{
    NSString *lowercase = selectorName.lowercaseString;
    return [lowercase rangeOfString:@"press"].location != NSNotFound ||
           [lowercase rangeOfString:@"button"].location != NSNotFound ||
           [lowercase rangeOfString:@"lock"].location != NSNotFound ||
           [lowercase rangeOfString:@"wake"].location != NSNotFound;
}

@implementation KSAPowerButton
{
    NSMutableArray<NSString *> *_installedWatchers;
    NSLock *_stateLock;
    NSTimeInterval _lastEventTime;
}

+ (instancetype)sharedInstance
{
    static KSAPowerButton *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KSAPowerButton alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _installedWatchers = [NSMutableArray array];
        _stateLock = [[NSLock alloc] init];
    }
    return self;
}

#pragma mark - Start / bookkeeping

- (void)noteSpringBoardReady
{
    // The constructor runs on SpringBoard's boot thread: never do real work here.
    // The probe is read-only and only useful with DebugEnabled = 1.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self logDiagnostics];
        KSAInfo(@"power button hooks: none installed at load time (lazy install on first alert)");
    });
}

- (void)noteWatcherInstalled:(NSString *)watcher
{
    if (watcher.length == 0) {
        return;
    }
    [_stateLock lock];
    [_installedWatchers addObject:watcher];
    [_stateLock unlock];
}

#pragma mark - Events

- (void)noteEvent:(NSString *)eventName
{
    if (eventName.length == 0) {
        return;
    }

    // Fast path first: this runs on SpringBoard's button handling thread. When no
    // alert is playing we return without taking a lock, touching the configuration
    // file or allocating anything.
    if (![[KSAAlertManager sharedInstance] isAlerting]) {
        KSADebug(@"power button event %@ while no alert is running (original behaviour untouched)",
                 eventName);
        return;
    }

    NSTimeInterval now = KSANow();
    [_stateLock lock];
    BOOL recentlyNoted = (now - _lastEventTime) < 0.25;
    _lastEventTime = now;
    [_stateLock unlock];

    if (recentlyNoted) {
        // The same physical press can travel through two hooked methods; only the
        // first one has to stop the alert.
        KSADebug(@"ignoring duplicate button event %@", eventName);
        return;
    }

    if (![KSAConfig sharedInstance].enabled) {
        return;
    }

    KSAInfo(@"power button pressed - stopping alert");
    [[KSAAlertManager sharedInstance] stopAlertWithReason:
     [NSString stringWithFormat:@"power button (%@)", eventName]];

    // The original implementation already ran unchanged, so lock / wake / Siri
    // behaviour is preserved.
}

#pragma mark - Diagnostics

- (void)logDiagnostics
{
    if (!KSALogDebugEnabled()) {
        return;
    }

    for (NSUInteger index = 0; index < kKSADiagnosticClassCount; index++) {
        NSString *className = kKSADiagnosticClasses[index];
        Class clazz = objc_getClass(className.UTF8String);
        if (clazz == Nil) {
            KSADebug(@"diagnostics: %@ = <missing>", className);
            continue;
        }

        NSMutableArray<NSString *> *interesting = [NSMutableArray array];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(clazz, &methodCount);
        for (unsigned int methodIndex = 0; methods != NULL && methodIndex < methodCount; methodIndex++) {
            NSString *selectorName = NSStringFromSelector(method_getName(methods[methodIndex]));
            if (KSASelectorIsInteresting(selectorName)) {
                [interesting addObject:selectorName];
            }
        }
        if (methods != NULL) {
            free(methods);
        }

        KSADebug(@"diagnostics: %@ (%u methods) candidates=[%@]",
                 className, methodCount,
                 interesting.count ? [interesting componentsJoinedByString:@", "] : @"none");
    }
}

- (NSString *)diagnostics
{
    [_stateLock lock];
    NSArray<NSString *> *watchers = [_installedWatchers copy];
    [_stateLock unlock];

    if (watchers.count == 0) {
        return @"none installed";
    }
    return [watchers componentsJoinedByString:@"; "];
}

@end
