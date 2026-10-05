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
#import <substrate.h>
#import <ctype.h>
#import <string.h>

/// Discovery targets inside SpringBoard.
///
/// NOTE: SBHIDButtonStateArbiter is deliberately NOT a target - it belongs to the
/// camera shutter / volume arbiter path, not to the side/power button (its only
/// delegate conformers are SBCameraHardwareButton and
/// SBHIDValueModifyingButtonSetArbiter; verified in the iOS 13.6/14.0 headers and
/// unchanged in the iOS 15.6 symbol table). See docs/power-button-hook-research.md.
///
/// The side/power button entry points that are known by name are hooked with exact
/// signatures in KeywordSMSAlertAlert.xm; this list is only the "catch anything else
/// this build exposes" pass.
static NSString *const kKSAPowerButtonCandidateClasses[] = {
    @"SBLockHardwareButton",
    @"SBHardwareButton",
    @"SBBacklightController",
};
static const NSUInteger kKSAPowerButtonCandidateClassCount =
    sizeof(kKSAPowerButtonCandidateClasses) / sizeof(kKSAPowerButtonCandidateClasses[0]);

/// Trampoline used for every discovered hardware-button method. Three pointer
/// sized argument slots cover every selector we accept (see
/// KSATypeEncodingIsSafelyHookable()).
typedef void (*KSAHardwareButtonIMP)(id, SEL, void *, void *, void *);

static NSMutableDictionary<NSString *, NSValue *> *KSAOriginalIMPs(void)
{
    static NSMutableDictionary<NSString *, NSValue *> *originalIMPs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        originalIMPs = [NSMutableDictionary dictionary];
    });
    return originalIMPs;
}

static void KSAHardwareButtonTrampoline(id self, SEL _cmd, void *arg1, void *arg2, void *arg3)
{
    NSString *selectorName = NSStringFromSelector(_cmd);

    NSValue *original = nil;
    @synchronized (KSAOriginalIMPs()) {
        original = KSAOriginalIMPs()[selectorName];
    }

    if (original != nil) {
        KSAHardwareButtonIMP implementation = (KSAHardwareButtonIMP)original.pointerValue;
        implementation(self, _cmd, arg1, arg2, arg3);
    }

    [[KSAPowerButton sharedInstance] noteEvent:selectorName];
}

/// Only hook methods that:
///   * return void,
///   * take at most three pointer/integer arguments (so the fixed trampoline above
///     can forward them unchanged),
///   * take no floating point or by-value struct arguments.
/// This keeps the trampoline ABI safe on arm64e.
static BOOL KSATypeEncodingIsSafelyHookable(const char *typeEncoding)
{
    if (typeEncoding == NULL || typeEncoding[0] != 'v') {
        return NO;
    }

    NSUInteger index = 1;
    NSUInteger argumentCount = 0;

    while (typeEncoding[index] != '\0') {
        while (typeEncoding[index] != '\0' && strchr("rnNoORV", typeEncoding[index]) != NULL) {
            index++;
        }
        while (typeEncoding[index] != '\0' && isdigit((unsigned char)typeEncoding[index])) {
            index++;
        }
        if (typeEncoding[index] == '\0') {
            break;
        }

        char type = typeEncoding[index];
        if (type == 'f' || type == 'd' || type == '{' || type == '[' || type == '(') {
            return NO;
        }

        argumentCount++;
        index++;
    }

    // self + _cmd are part of the encoding.
    return argumentCount >= 2 && argumentCount <= 5;
}

static BOOL KSASelectorLooksLikeButtonAction(NSString *selectorName)
{
    if (selectorName.length == 0) {
        return NO;
    }

    NSString *lowercase = selectorName.lowercaseString;
    if ([lowercase rangeOfString:@"press"].location == NSNotFound) {
        return NO;
    }

    // SpringBoard's hardware button action family, e.g.:
    //   performPressActions / performLongPressActions /
    //   performDoublePressActions / performTriplePressActions
    // plus the lower level button callbacks some builds use instead
    //   buttonDown / _buttonDown: / handleButtonPress ...
    // Everything is still gated by the runtime existence check and by
    // KSATypeEncodingIsSafelyHookable(), so a selector we cannot forward safely is
    // skipped and logged instead of being hooked blindly.
    return [lowercase hasSuffix:@"actions"] ||
           [lowercase hasPrefix:@"button"] ||
           [lowercase hasPrefix:@"_button"] ||
           [lowercase hasPrefix:@"handlebutton"];
}

static BOOL KSASelectorLooksLikeBacklightOn(NSString *selectorName)
{
    if (selectorName.length == 0) {
        return NO;
    }
    NSString *lowercase = selectorName.lowercaseString;
    return [lowercase rangeOfString:@"turnonbacklight"].location != NSNotFound ||
           [lowercase rangeOfString:@"backlighton"].location != NSNotFound ||
           [lowercase rangeOfString:@"setbacklighton"].location != NSNotFound;
}

@implementation KSAPowerButton
{
    NSMutableArray<NSString *> *_installedWatchers;
    NSMutableSet<NSString *> *_excludedSelectors;
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
        _excludedSelectors = [NSMutableSet set];
        _stateLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)skipSelectorNames:(NSArray<NSString *> *)selectorNames
{
    if (selectorNames.count == 0) {
        return;
    }
    [_stateLock lock];
    [_excludedSelectors addObjectsFromArray:selectorNames];
    [_stateLock unlock];
    KSADebug(@"discovery will skip already hooked selectors: %@",
             [selectorNames componentsJoinedByString:@", "]);
}

#pragma mark - Start / discovery

- (void)startInSpringBoard
{
    [self logDiagnostics];
    [self _installDiscoveredWatchers];
    KSAInfo(@"power button watchers: %@", [self diagnostics]);
}

- (void)_installDiscoveredWatchers
{
    for (NSUInteger index = 0; index < kKSAPowerButtonCandidateClassCount; index++) {
        NSString *className = kKSAPowerButtonCandidateClasses[index];
        Class clazz = objc_getClass(className.UTF8String);
        if (clazz == Nil) {
            KSADebug(@"candidate class %@ not present in this process", className);
            continue;
        }

        BOOL wantsBacklight = [className isEqualToString:@"SBBacklightController"];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(clazz, &methodCount);
        if (methods == NULL) {
            continue;
        }

        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
            SEL selector = method_getName(methods[methodIndex]);
            NSString *selectorName = NSStringFromSelector(selector);

            BOOL matches = wantsBacklight ? KSASelectorLooksLikeBacklightOn(selectorName)
                                          : KSASelectorLooksLikeButtonAction(selectorName);
            if (!matches) {
                continue;
            }

            [_stateLock lock];
            BOOL excluded = [_excludedSelectors containsObject:selectorName];
            [_stateLock unlock];
            if (excluded) {
                KSADebug(@"%@ -%@ already hooked with an exact signature; skipping", className, selectorName);
                continue;
            }

            const char *typeEncoding = method_getTypeEncoding(methods[methodIndex]);
            if (!KSATypeEncodingIsSafelyHookable(typeEncoding)) {
                KSAInfo(@"skipping %@ -%@: signature is not a plain void method (%s)",
                        className, selectorName, typeEncoding ?: "?");
                continue;
            }

            IMP original = NULL;
            @synchronized (KSAOriginalIMPs()) {
                if (KSAOriginalIMPs()[selectorName] != nil) {
                    // Already hooked through another class; skip to avoid a
                    // duplicated trampoline for the inherited implementation.
                    KSADebug(@"%@ -%@ already hooked", className, selectorName);
                    continue;
                }
            }

            MSHookMessageEx(clazz, selector, (IMP)&KSAHardwareButtonTrampoline, &original);
            if (original == NULL) {
                KSAInfo(@"unable to hook %@ -%@", className, selectorName);
                continue;
            }

            @synchronized (KSAOriginalIMPs()) {
                KSAOriginalIMPs()[selectorName] = [NSValue valueWithPointer:(void *)original];
            }

            NSString *watcher = [NSString stringWithFormat:@"%@ -%@", className, selectorName];
            [_stateLock lock];
            [_installedWatchers addObject:watcher];
            [_stateLock unlock];
            KSAInfo(@"watching %@", watcher);
        }

        free(methods);
    }
}

#pragma mark - Events

- (void)noteEvent:(NSString *)eventName
{
    if (eventName.length == 0) {
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

    // Fast path first: this hook runs on SpringBoard's press handling thread, so
    // when no alert is playing we return without touching the configuration file.
    if (![[KSAAlertManager sharedInstance] isAlerting]) {
        KSADebug(@"power button event %@ while no alert is running (original behaviour untouched)", eventName);
        return;
    }

    KSADebug(@"power button event: %@", eventName);

    if (![KSAConfig sharedInstance].enabled) {
        return;
    }

    KSAInfo(@"power button pressed - stopping alert");
    [[KSAAlertManager sharedInstance] stopAlertWithReason:
     [NSString stringWithFormat:@"power button (%@)", eventName]];

    // The original implementation already ran (or will run) unchanged, so lock /
    // wake / Siri behaviour is preserved.
}

#pragma mark - Diagnostics

- (void)logDiagnostics
{
    if (!KSALogDebugEnabled()) {
        return;
    }

    for (NSUInteger index = 0; index < kKSAPowerButtonCandidateClassCount; index++) {
        NSString *className = kKSAPowerButtonCandidateClasses[index];
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
            NSString *lowercase = selectorName.lowercaseString;
            if ([lowercase rangeOfString:@"press"].location != NSNotFound ||
                [lowercase rangeOfString:@"button"].location != NSNotFound ||
                [lowercase rangeOfString:@"backlight"].location != NSNotFound ||
                [lowercase rangeOfString:@"lock"].location != NSNotFound) {
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
