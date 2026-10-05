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
        [[KSASMSWatcher sharedInstance] start];
    }
}
