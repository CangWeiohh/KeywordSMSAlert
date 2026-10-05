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
//  Every hook calls the original implementation and keeps its behaviour; pressing
//  the power button still locks/wakes the device exactly as before.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

#import "KSAAlertManager.h"
#import "KSACommon.h"
#import "KSAConfig.h"
#import "KSALog.h"
#import "KSAPowerButton.h"

#import "KSAPrivateAPI.h"

#pragma mark - Verified SpringBoard hook

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
%group KSASleepWakeConsumeHooks
%hook SBSleepWakeHardwareButtonInteraction
- (BOOL)consumeInitialPressDown
{
    @try {
        [[KSAPowerButton sharedInstance] noteEvent:@"consumeInitialPressDown"];
    } @catch (__unused NSException *exception) {
    }
    return %orig;
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

#pragma mark - Entry point

static void KSASetupSpringBoard(void)
{
    Class lockScreenManager = objc_getClass("SBLockScreenManager");
    if (lockScreenManager != Nil) {
        BOOL hooked = NO;
        if (class_getInstanceMethod(lockScreenManager, @selector(lockUIFromSource:withOptions:))) {
            %init(KSALockUIHooks);
            KSAInfo(@"hooked SBLockScreenManager -lockUIFromSource:withOptions:");
            hooked = YES;
        }
        if (class_getInstanceMethod(lockScreenManager, @selector(lockUIFromSource:))) {
            %init(KSALockUILegacyHooks);
            KSAInfo(@"hooked SBLockScreenManager -lockUIFromSource:");
            hooked = YES;
        }
        if (!hooked) {
            KSAInfo(@"SBLockScreenManager present but no lockUIFromSource: selector found");
        }
    } else {
        KSAInfo(@"SBLockScreenManager not found; relying on discovered hardware button watchers");
    }

    // Verified press-DOWN hooks first, then the generic discovery pass (which skips
    // anything already hooked above).
    NSMutableArray<NSString *> *alreadyHooked = [NSMutableArray array];

    Class sleepWakeInteraction = objc_getClass("SBSleepWakeHardwareButtonInteraction");
    if (sleepWakeInteraction != Nil &&
        class_getInstanceMethod(sleepWakeInteraction, @selector(consumeInitialPressDown))) {
        %init(KSASleepWakeConsumeHooks);
        [alreadyHooked addObject:@"consumeInitialPressDown"];
        KSAInfo(@"hooked SBSleepWakeHardwareButtonInteraction -consumeInitialPressDown");
    } else {
        KSAInfo(@"SBSleepWakeHardwareButtonInteraction -consumeInitialPressDown not available");
    }

    Class buttonActions = objc_getClass("SBLockHardwareButtonActions");
    if (buttonActions != Nil &&
        class_getInstanceMethod(buttonActions, @selector(performInitialButtonDownActions))) {
        %init(KSALockButtonActionsHooks);
        [alreadyHooked addObject:@"performInitialButtonDownActions"];
        KSAInfo(@"hooked SBLockHardwareButtonActions -performInitialButtonDownActions");
    } else {
        KSAInfo(@"SBLockHardwareButtonActions -performInitialButtonDownActions not available");
    }

    Class lockButton = objc_getClass("SBLockHardwareButton");
    if (lockButton != Nil &&
        class_getInstanceMethod(lockButton, @selector(buttonDown:))) {
        %init(KSALockButtonDownHooks);
        [alreadyHooked addObject:@"buttonDown:"];
        KSAInfo(@"hooked SBLockHardwareButton -buttonDown:");
    } else {
        KSAInfo(@"SBLockHardwareButton -buttonDown: not available");
    }

    // Discovery based watchers (anything else this build happens to expose) and the
    // alert engine itself.
    [[KSAPowerButton sharedInstance] skipSelectorNames:alreadyHooked];
    [[KSAPowerButton sharedInstance] startInSpringBoard];
    [[KSAAlertManager sharedInstance] start];

    if ([KSAConfig sharedInstance].testAlertOnLoad) {
        KSAInfo(@"TestAlertOnLoad is enabled: firing a test alert in 3 seconds");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            KSAMatchEvent *event = [[KSAMatchEvent alloc] init];
            event.source = @"test";
            event.text = @"KeywordSMSAlert self test";
            event.keyword = @"self test";
            [[KSAAlertManager sharedInstance] handleMatchEvent:event];
        });
    }
}

%ctor
{
    @autoreleasepool {
        if (!KSAIsSpringBoardProcess()) {
            KSADebug(@"alert dylib loaded outside SpringBoard (%@); idle",
                     KSAProcessBundleIdentifier() ?: @"?");
            return;
        }

        KSAInfo(@"alert dylib loaded into %@ (pid %d)", KSAProcessName(), getpid());

        @try {
            KSASetupSpringBoard();
        } @catch (NSException *exception) {
            KSAInfo(@"alert setup failed (tweak disabled): %@", exception.reason);
        }
    }
}
