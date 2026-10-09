//
//  KeywordSMSAlertDetector.xm
//  KeywordSMSAlert - detector dylib (imagent only)
//
//  Filter: com.apple.imagent
//
//  HOOK FREE BY DESIGN.
//
//  History: up to 1.0.7 this dylib hooked the imagent message pipeline
//  (SMSServiceSession / IMDMessageStore / IMDServiceSession). On a real iPhone 12 /
//  iOS 15.4.1 that produced a reproducible crash loop: every crash report showed
//
//      EXC_BAD_ACCESS (SIGSEGV) objc_retain
//        -> KeywordSMSAlertDetector.dylib   (our main queue block)
//        -> SMS (SMS.imservice plugin)
//        -> imagent main run loop
//
//  i.e. hooking a lazily loaded service-plugin class right after its
//  -loadServiceBundle window left a dangling reference and the plugin crashed on
//  objc_retain. launchd kept restarting imagent, so no SMS could be received at all.
//  The hook based mode was therefore REMOVED in 1.1.1: this dylib now contains no
//  hooks whatsoever and cannot affect SMS reception.
//
//  Detection is done by KSASMSWatcher: it polls sms.db READ ONLY on its own serial
//  queue (SQLITE_OPEN_READONLY) and reports new incoming rows.
//  To stop everything: Enabled = false, then restart imagent.
//

#import <Foundation/Foundation.h>
#import <unistd.h>

#import "KSACommon.h"
#import "KSAConfig.h"
#import "KSALog.h"
#import "KSASMSDetector.h"
#import "KSASMSWatcher.h"
#import "KSATrigger.h"

#ifdef KSA_ALERT_IN_DETECTOR
#import "KSAAlertManager.h"
#import "Daemon/KSADisplayStateStop.h"
#import "Daemon/KSARuntimeStatus.h"
#endif

%ctor
{
    @autoreleasepool {
        if (!KSAIsIMAgentProcess()) {
            KSADebug(@"detector dylib loaded outside imagent (%@); idle",
                     KSAProcessBundleIdentifier() ?: @"?");
            return;
        }

        KSAInfo(@"detector loaded into %@ (pid %d) - hook free detector",
                KSAProcessName(), getpid());

        [[KSASMSDetector sharedInstance] start];

        KSAConfig *config = [KSAConfig sharedInstance];
        if (!config.enabled) {
            KSAInfo(@"plugin disabled (Enabled=false): nothing is installed or polled in imagent");
            return;
        }

        KSAInfo(@"detection: read only SMS database polling every %.1fs (no hooks in imagent)",
                config.pollInterval);

#ifdef KSA_ALERT_IN_DETECTOR
        // 1.2.0: the alert engine runs here, in imagent. No SpringBoard injection and
        // no launchd service - on this device both of those reproduced the CallAssist
        // userspace-reboot black screen.
        KSARuntimeStatusReset();
        [[KSAAlertManager sharedInstance] start];
        [[KSADisplayStateStop sharedInstance] start];
        KSAInfo(@"alert engine hosted in imagent (vibration + alert channel sound)");

        if (config.testAlertOnLoad) {
            KSAInfo(@"TestAlertOnLoad is enabled: firing a test alert in 3 seconds");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                KSAMatchEvent *event = [[KSAMatchEvent alloc] init];
                event.source = @"imagent self test";
                event.text = @"KeywordSMSAlert self test";
                event.keyword = @"self test";
                [[KSAAlertManager sharedInstance] handleMatchEvent:event];
            });
        }
#else
        KSATriggerPost();
#endif

        [[KSASMSWatcher sharedInstance] start];
    }
}
