//
//  KeywordSMSAlertAlert.xm
//  KeywordSMSAlert - alert dylib (SpringBoard only)
//
//  Filter: com.apple.springboard
//
//  SpringBoard is the only process that always runs, owns audio/haptics and can
//  observe the physical side button. It therefore hosts:
//    * the Alert Engine (vibration + sound, own serial queue, state machine),
//    * the power button watcher,
//    * the listener for the Darwin notification posted by the detector in imagent.
//
//  1.1.3 - "no work during SpringBoard's early boot":
//
//  A userspace reboot loads every tweak into SpringBoard while SpringBoard itself
//  is still coming up. Doing anything heavy there - and especially installing
//  hooks (each MSHookMessageEx call suspends the other threads) - can turn a
//  harmless millisecond hiccup into a SpringBoard whose display state machine
//  never finishes: the process keeps running, the system works, but the screen
//  stays black. That was observed on a real device in combination with another
//  SpringBoard tweak that also installs hooks at load time.
//
//  Therefore:
//    * the constructor does NOT install a single hook - it only identifies the
//      process, honours the emergency kill switch and starts the (asynchronous,
//      hook-free) alert engine;
//    * the button/lock hooks are installed on the first alert that really starts,
//      i.e. when SpringBoard is fully up and running (see KSAHookInstaller.h);
//    * the emergency marker file makes this process install nothing at all.
//
//  Every hook calls the original implementation and keeps its behaviour; pressing
//  the power button still locks/wakes the device exactly as before.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

#import "KSAAlertManager.h"
#import "KSACommon.h"
#import "KSAConfig.h"
#import "KSAHookInstaller.h"
#import "KSALog.h"
#import "KSAPowerButton.h"

#import "KSAPrivateAPI.h"

#pragma mark - Verified SpringBoard hooks (installed lazily)

//
// Power button pressed while the screen was on -> the screen locks. The original
// implementation always runs first, so locking keeps working normally; we only
// observe the event to stop a running alert.
//
%group KSALockUIHooks
%hook SBLockScreenManager
- (void)lockUIFromSource:(NSUInteger)source withOptions:(NSDictionary *)options
{
    %orig;
    @try {
        [[KSAPowerButton sharedInstance] noteEvent:@"lockUIFromSource"];
    } @catch (__unused NSException *exception) {
    }
}
%end
%end

%group KSALockUILegacyHooks
%hook SBLockScreenManager
- (void)lockUIFromSource:(NSUInteger)source
{
    %orig;
    @try {
        [[KSAPowerButton sharedInstance] noteEvent:@"lockUIFromSource"];
    } @catch (__unused NSException *exception) {
    }
}
%end
%end

#pragma mark - Verified press-DOWN hooks (cover both the lock and the wake case)

//
// Rank 1: the object that owns -_performSleep AND -_performWake is consulted on
// every press DOWN. The BOOL result is passed through untouched, so whether iOS
// consumes the press (SOS, Siri, registered apps, ...) is decided exactly as before.
//
// 1.1.3: the original now runs FIRST and our observation happens afterwards, so
// this hook is order/chain agnostic even when another tweak hooks the same method.
//
%group KSASleepWakeConsumeHooks
%hook SBSleepWakeHardwareButtonInteraction
- (BOOL)consumeInitialPressDown
{
    BOOL consumedByOriginal = %orig;
    @try {
        [[KSAPowerButton sharedInstance] noteEvent:@"consumeInitialPressDown"];
    } @catch (__unused NSException *exception) {
    }
    return consumedByOriginal;
}
%end
%end

//
// Rank 2: the button actions object receives the initial button-down for both
// screen states (shipping tweaks on iOS 14-16 use exactly this entry point).
//
%group KSALockButtonActionsHooks
%hook SBLockHardwareButtonActions
- (void)performInitialButtonDownActions
{
    %orig;
    @try {
        [[KSAPowerButton sharedInstance] noteEvent:@"performInitialButtonDownActions"];
    } @catch (__unused NSException *exception) {
    }
}
%end
%end

//
// Rank 3: the gesture driven button-down itself. Cheap redundancy for builds where
// one of the two hooks above is missing.
//
%group KSALockButtonDownHooks
%hook SBLockHardwareButton
- (void)buttonDown:(id)press
{
    %orig;
    @try {
        [[KSAPowerButton sharedInstance] noteEvent:@"buttonDown:"];
    } @catch (__unused NSException *exception) {
    }
}
%end
%end

#pragma mark - Lazy installation

/// Installs the hooks above (exact signatures, all of them pass `%orig` through).
/// Deliberately NOT called from the constructor - see the file header.
static void KSARecordWatcher(NSString *watcher)
{
    [[KSAPowerButton sharedInstance] noteWatcherInstalled:watcher];
    KSAInfo(@"hooked %@", watcher);
}

static void KSASetupSpringBoardHooks(void)
{
    Class lockScreenManager = objc_getClass("SBLockScreenManager");
    if (lockScreenManager != Nil) {
        BOOL hooked = NO;
        if (class_getInstanceMethod(lockScreenManager, @selector(lockUIFromSource:withOptions:))) {
            %init(KSALockUIHooks);
            KSARecordWatcher(@"SBLockScreenManager -lockUIFromSource:withOptions:");
            hooked = YES;
        }
        if (class_getInstanceMethod(lockScreenManager, @selector(lockUIFromSource:))) {
            %init(KSALockUILegacyHooks);
            KSARecordWatcher(@"SBLockScreenManager -lockUIFromSource:");
            hooked = YES;
        }
        if (!hooked) {
            KSAInfo(@"SBLockScreenManager present but no lockUIFromSource: selector found");
        }
    } else {
        KSAInfo(@"SBLockScreenManager not found in this build");
    }

    Class sleepWakeInteraction = objc_getClass("SBSleepWakeHardwareButtonInteraction");
    if (sleepWakeInteraction != Nil &&
        class_getInstanceMethod(sleepWakeInteraction, @selector(consumeInitialPressDown))) {
        %init(KSASleepWakeConsumeHooks);
        KSARecordWatcher(@"SBSleepWakeHardwareButtonInteraction -consumeInitialPressDown");
    } else {
        KSAInfo(@"SBSleepWakeHardwareButtonInteraction -consumeInitialPressDown not available");
    }

    Class buttonActions = objc_getClass("SBLockHardwareButtonActions");
    if (buttonActions != Nil &&
        class_getInstanceMethod(buttonActions, @selector(performInitialButtonDownActions))) {
        %init(KSALockButtonActionsHooks);
        KSARecordWatcher(@"SBLockHardwareButtonActions -performInitialButtonDownActions");
    } else {
        KSAInfo(@"SBLockHardwareButtonActions -performInitialButtonDownActions not available");
    }

    Class lockButton = objc_getClass("SBLockHardwareButton");
    if (lockButton != Nil &&
        class_getInstanceMethod(lockButton, @selector(buttonDown:))) {
        %init(KSALockButtonDownHooks);
        KSARecordWatcher(@"SBLockHardwareButton -buttonDown:");
    } else {
        KSAInfo(@"SBLockHardwareButton -buttonDown: not available");
    }

    // No discovery pass and no SBBacklightController: 1.1.1/1.1.2 wrapped *every*
    // backlight-on style method that this build happened to expose, which sits right
    // on the chain that decides whether the screen lights up at all. The four hooks
    // above are the ones that actually fire on iOS 15.4.1 and each of them keeps the
    // original behaviour, so nothing is lost by dropping the shotgun pass.
    KSAInfo(@"power button watcher active: %@", [[KSAPowerButton sharedInstance] diagnostics]);
}

static BOOL sKSAHooksInstalled = NO;
static NSLock *KSAInstallerLock(void)
{
    static NSLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

BOOL KSAPowerButtonHooksInstalled(void)
{
    NSLock *lock = KSAInstallerLock();
    [lock lock];
    BOOL installed = sKSAHooksInstalled;
    [lock unlock];
    return installed;
}

void KSAInstallPowerButtonHooksIfNeeded(void)
{
    if (!KSAIsSpringBoardProcess()) {
        return;
    }

    if (KSASafeModeEnabled()) {
        KSAInfo(@"safemode marker present at %@ - refusing to install any hook",
                KSASafeModeMarkerPath());
        return;
    }

    NSLock *lock = KSAInstallerLock();
    [lock lock];
    BOOL alreadyInstalled = sKSAHooksInstalled;
    if (!alreadyInstalled) {
        sKSAHooksInstalled = YES;   // set first: never install twice, even on a throw
    }
    [lock unlock];

    if (alreadyInstalled) {
        return;
    }

    KSAInfo(@"installing power button hooks on demand (first alert)");
    @try {
        KSASetupSpringBoardHooks();
    } @catch (NSException *exception) {
        KSAInfo(@"power button hook installation failed: %@", exception.reason);
    }
}

#pragma mark - Entry point

%ctor
{
    @autoreleasepool {
        if (!KSAIsSpringBoardProcess()) {
            KSADebug(@"alert dylib loaded outside SpringBoard (%@); idle",
                     KSAProcessBundleIdentifier() ?: @"?");
            return;
        }

        KSAInfo(@"alert dylib loaded into %@ (pid %d) - no hook installed at load time",
                KSAProcessName(), getpid());

        if (KSASafeModeEnabled()) {
            KSAInfo(@"safemode marker present at %@ - this process will install no hook at all",
                    KSASafeModeMarkerPath());
        }

        // Everything below is asynchronous and hook free: reading the configuration
        // and registering observers must not run on SpringBoard's boot thread.
        [[KSAPowerButton sharedInstance] noteSpringBoardReady];
        [[KSAAlertManager sharedInstance] start];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (![KSAConfig sharedInstance].testAlertOnLoad) {
                return;
            }
            KSAInfo(@"TestAlertOnLoad is enabled: firing a test alert in 3 seconds");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                KSAMatchEvent *event = [[KSAMatchEvent alloc] init];
                event.source = @"test";
                event.text = @"KeywordSMSAlert self test";
                event.keyword = @"self test";
                [[KSAAlertManager sharedInstance] handleMatchEvent:event];
            });
        });
    }
}
