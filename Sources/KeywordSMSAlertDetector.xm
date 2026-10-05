//
//  KeywordSMSAlertDetector.xm
//  KeywordSMSAlert - detector dylib (imagent only)
//
//  Filter: com.apple.imagent
//
//  This dylib is deliberately tiny: it links only Foundation/CoreFoundation, the
//  roothide API and the substrate hooking runtime. It does NOT link AVFoundation
//  or AudioToolbox, so injecting it into the SMS daemon cannot drag audio
//  frameworks, audio sessions or UI code into a critical system daemon.
//
//  It does exactly three things, all on the daemon's message thread and all fast:
//    1. let the original method run and return its original result untouched,
//    2. look at the message object it produced (sender / text / GUID),
//    3. on a keyword match, post a Darwin notification to SpringBoard.
//
//  The SMS database, the notification centre, the Messages UI and the message flow
//  itself are never modified.
//
//  Hook families, in order of preference:
//    A. SMSServiceSession (earliest, SMS specific, SMS.imservice plugin)
//       -_convertCTMessageToDictionary:requiresUpload:
//       -_receivedSMSDictionary:requiresUpload:isBeingReplayed:
//       Selectors observed on device by tracing imagent; verified at runtime here,
//       and reported in the diagnostics log if they ever disappear.
//    B. IMDMessageStore (IMDaemonCore) - backstop, signatures verified against the
//       iOS 15.6 runtime headers. Runs for every stored message independent of
//       notification/DND/foreground state and carries body + guid.
//       -storeItem:forceReplace:
//       -storeMessage:forceReplace:modifyError:modifyFlags:flagMask:[updateMessageCache:calculateUnreadCount:[reindexMessage:]]
//    C. IMDServiceSession -didReceiveMessage:forChat:style:... - generic backstop.
//
//  Duplicates between A/B/C are collapsed by the GUID based de-duplication cache.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <unistd.h>

#import "KSACommon.h"
#import "KSAConfig.h"
#import "KSALog.h"
#import "KSASMSDetector.h"
#import "KSATrigger.h"

#import "KSAPrivateAPI.h"

// Defined further down; used by the IMDService hook.
static void KSAInstallAvailableHooks(void);

#pragma mark - A. SMSServiceSession (SMS service plugin)

//
// The SMS service bundle loads lazily, so SMSServiceSession does not exist when
// our constructor runs. This hook is the first reliable signal that it appeared.
//
%group KSASMSDefinitionHooks
%hook IMDService
- (void)loadServiceBundle
{
    %orig;

    // Never install hooks from inside the bundle loading call stack; hop to the
    // main queue so the class hierarchy is fully settled.
    dispatch_async(dispatch_get_main_queue(), ^{
        KSAInstallAvailableHooks();
    });
}
%end
%end

%group KSASMSConvertHooks
%hook SMSServiceSession
- (id)_convertCTMessageToDictionary:(id)message requiresUpload:(BOOL)requiresUpload
{
    id result = %orig;
    @try {
        [[KSASMSDetector sharedInstance] handleCTMessage:message
                                             dictionary:result
                                                 source:@"_convertCTMessageToDictionary"];
    } @catch (__unused NSException *exception) {
    }
    return result;
}
%end
%end

%group KSASMSReceivedHooks
%hook SMSServiceSession
- (id)_receivedSMSDictionary:(id)message requiresUpload:(BOOL)requiresUpload isBeingReplayed:(BOOL)isBeingReplayed
{
    id result = %orig;
    @try {
        [[KSASMSDetector sharedInstance] handleCTMessage:message
                                             dictionary:result
                                                 source:@"_receivedSMSDictionary"];
    } @catch (__unused NSException *exception) {
    }
    return result;
}
%end
%end

#pragma mark - B. IMDMessageStore (IMDaemonCore backstop)

%group KSAStoreItemHooks
%hook IMDMessageStore
- (id)storeItem:(id)item forceReplace:(BOOL)forceReplace
{
    id result = %orig;
    @try {
        [[KSASMSDetector sharedInstance] handleMessageItem:item source:@"IMDMessageStore.storeItem"];
    } @catch (__unused NSException *exception) {
    }
    return result;
}
%end
%end

%group KSAStoreMessage5Hooks
%hook IMDMessageStore
- (id)storeMessage:(id)message forceReplace:(BOOL)forceReplace modifyError:(BOOL)modifyError modifyFlags:(BOOL)modifyFlags flagMask:(NSUInteger)flagMask
{
    id result = %orig;
    @try {
        [[KSASMSDetector sharedInstance] handleMessageItem:message source:@"IMDMessageStore.storeMessage5"];
    } @catch (__unused NSException *exception) {
    }
    return result;
}
%end
%end

%group KSAStoreMessage7Hooks
%hook IMDMessageStore
- (id)storeMessage:(id)message forceReplace:(BOOL)forceReplace modifyError:(BOOL)modifyError modifyFlags:(BOOL)modifyFlags flagMask:(NSUInteger)flagMask updateMessageCache:(BOOL)updateMessageCache calculateUnreadCount:(BOOL)calculateUnreadCount
{
    id result = %orig;
    @try {
        [[KSASMSDetector sharedInstance] handleMessageItem:message source:@"IMDMessageStore.storeMessage7"];
    } @catch (__unused NSException *exception) {
    }
    return result;
}
%end
%end

%group KSAStoreMessage8Hooks
%hook IMDMessageStore
- (id)storeMessage:(id)message forceReplace:(BOOL)forceReplace modifyError:(BOOL)modifyError modifyFlags:(BOOL)modifyFlags flagMask:(NSUInteger)flagMask updateMessageCache:(BOOL)updateMessageCache calculateUnreadCount:(BOOL)calculateUnreadCount reindexMessage:(BOOL)reindexMessage
{
    id result = %orig;
    @try {
        [[KSASMSDetector sharedInstance] handleMessageItem:message source:@"IMDMessageStore.storeMessage8"];
    } @catch (__unused NSException *exception) {
    }
    return result;
}
%end
%end

#pragma mark - C. IMDServiceSession (generic backstop)

%group KSADidReceive5Hooks
%hook IMDServiceSession
- (void)didReceiveMessage:(id)message forChat:(id)chat style:(unsigned char)style account:(id)account fromIDSID:(id)fromIDSID
{
    %orig;
    @try {
        [[KSASMSDetector sharedInstance] handleMessageItem:message source:@"IMDServiceSession.didReceiveMessage5"];
    } @catch (__unused NSException *exception) {
    }
}
%end
%end

%group KSADidReceive4Hooks
%hook IMDServiceSession
- (void)didReceiveMessage:(id)message forChat:(id)chat style:(unsigned char)style fromIDSID:(id)fromIDSID
{
    %orig;
    @try {
        [[KSASMSDetector sharedInstance] handleMessageItem:message source:@"IMDServiceSession.didReceiveMessage4"];
    } @catch (__unused NSException *exception) {
    }
}
%end
%end

#pragma mark - Installation (lazy classes, runtime verified)

static BOOL sInstalledSMSServiceHooks = NO;
static BOOL sInstalledMessageStoreHooks = NO;
static BOOL sInstalledServiceSessionHooks = NO;
static NSUInteger sInstallAttempts = 0;

static void KSAInstallAvailableHooks(void)
{
    @try {
        if (!sInstalledSMSServiceHooks) {
            Class clazz = objc_getClass("SMSServiceSession");
            if (clazz != Nil) {
                BOOL hooked = NO;
                if (class_getInstanceMethod(clazz, @selector(_convertCTMessageToDictionary:requiresUpload:))) {
                    %init(KSASMSConvertHooks);
                    KSAInfo(@"hooked SMSServiceSession -_convertCTMessageToDictionary:requiresUpload:");
                    hooked = YES;
                }
                if (class_getInstanceMethod(clazz, @selector(_receivedSMSDictionary:requiresUpload:isBeingReplayed:))) {
                    %init(KSASMSReceivedHooks);
                    KSAInfo(@"hooked SMSServiceSession -_receivedSMSDictionary:requiresUpload:isBeingReplayed:");
                    hooked = YES;
                }
                sInstalledSMSServiceHooks = hooked;
                if (!hooked) {
                    KSAInfo(@"SMSServiceSession exists but neither traced selector is present "
                             "on this build; relying on the IMDMessageStore backstop");
                }
            }
        }

        if (!sInstalledMessageStoreHooks) {
            Class clazz = objc_getClass("IMDMessageStore");
            if (clazz != Nil) {
                BOOL hooked = NO;
                if (class_getInstanceMethod(clazz, @selector(storeItem:forceReplace:))) {
                    %init(KSAStoreItemHooks);
                    KSAInfo(@"hooked IMDMessageStore -storeItem:forceReplace:");
                    hooked = YES;
                }
                if (class_getInstanceMethod(clazz, @selector(storeMessage:forceReplace:modifyError:modifyFlags:flagMask:))) {
                    %init(KSAStoreMessage5Hooks);
                    KSAInfo(@"hooked IMDMessageStore -storeMessage:(5 args)");
                    hooked = YES;
                }
                if (class_getInstanceMethod(clazz, @selector(storeMessage:forceReplace:modifyError:modifyFlags:flagMask:updateMessageCache:calculateUnreadCount:))) {
                    %init(KSAStoreMessage7Hooks);
                    KSAInfo(@"hooked IMDMessageStore -storeMessage:(7 args)");
                    hooked = YES;
                }
                if (class_getInstanceMethod(clazz, @selector(storeMessage:forceReplace:modifyError:modifyFlags:flagMask:updateMessageCache:calculateUnreadCount:reindexMessage:))) {
                    %init(KSAStoreMessage8Hooks);
                    KSAInfo(@"hooked IMDMessageStore -storeMessage:(8 args)");
                    hooked = YES;
                }
                sInstalledMessageStoreHooks = hooked;
            }
        }

        if (!sInstalledServiceSessionHooks) {
            Class clazz = objc_getClass("IMDServiceSession");
            if (clazz != Nil) {
                BOOL hooked = NO;
                if (class_getInstanceMethod(clazz, @selector(didReceiveMessage:forChat:style:account:fromIDSID:))) {
                    %init(KSADidReceive5Hooks);
                    KSAInfo(@"hooked IMDServiceSession -didReceiveMessage:(5 args)");
                    hooked = YES;
                }
                if (class_getInstanceMethod(clazz, @selector(didReceiveMessage:forChat:style:fromIDSID:))) {
                    %init(KSADidReceive4Hooks);
                    KSAInfo(@"hooked IMDServiceSession -didReceiveMessage:(4 args)");
                    hooked = YES;
                }
                sInstalledServiceSessionHooks = hooked;
            }
        }

        if (sInstalledSMSServiceHooks && sInstalledMessageStoreHooks && sInstalledServiceSessionHooks) {
            KSALogSMSServiceSessionDiagnostics();
        }
    } @catch (NSException *exception) {
        KSAInfo(@"installing detector hooks failed: %@", exception.reason);
    }
}

/// Bounded safety net: 20 attempts over ~5 seconds, then it gives up and reports the
/// runtime selectors it found instead of failing silently. This is not a polling
/// loop for any user facing feature; it only waits for lazily loaded classes.
static void KSAScheduleHookInstallRetries(void)
{
    BOOL everythingInstalled = sInstalledSMSServiceHooks &&
                               sInstalledMessageStoreHooks &&
                               sInstalledServiceSessionHooks;

    if (everythingInstalled || sInstallAttempts >= 20) {
        if (!everythingInstalled) {
            KSAInfo(@"some detector hooks could not be installed (sms=%d store=%d session=%d); "
                     "see the diagnostics lines above for the selectors this build actually has",
                     sInstalledSMSServiceHooks, sInstalledMessageStoreHooks, sInstalledServiceSessionHooks);
            KSALogSMSServiceSessionDiagnostics();
        }
        return;
    }

    sInstallAttempts++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        KSAInstallAvailableHooks();
        KSAScheduleHookInstallRetries();
    });
}

/// dyld tells us whenever a new image is mapped - exactly what happens when the SMS
/// service bundle is loaded. Event driven, no polling.
static void KSAImageAddedCallback(const struct mach_header *header, intptr_t slide)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        KSAInstallAvailableHooks();
    });
}

#pragma mark - Entry point

%ctor
{
    @autoreleasepool {
        if (!KSAIsIMAgentProcess()) {
            KSADebug(@"detector dylib loaded outside imagent (%@); idle",
                     KSAProcessBundleIdentifier() ?: @"?");
            return;
        }

        KSAInfo(@"detector loaded into %@ (pid %d)", KSAProcessName(), getpid());
        [[KSASMSDetector sharedInstance] start];

        Class serviceClass = objc_getClass("IMDService");
        if (serviceClass != Nil &&
            class_getInstanceMethod(serviceClass, @selector(loadServiceBundle)) != NULL) {
            %init(KSASMSDefinitionHooks);
            KSAInfo(@"watching IMDService -loadServiceBundle for the SMS service bundle");
        } else {
            KSAInfo(@"IMDService -loadServiceBundle not available; using dyld image notifications only");
        }

        KSAInstallAvailableHooks();
        _dyld_register_func_for_add_image(&KSAImageAddedCallback);
        KSAScheduleHookInstallRetries();
    }
}
