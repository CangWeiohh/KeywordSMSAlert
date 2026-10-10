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

        KSAInfo(@"detector loaded into %@ (pid %d) - hook free detector", KSAProcessName(), getpid());

#ifdef KSA_ALERT_IN_DETECTOR
        // ---------------------------------------------------------------------
        // BOOT-QUIET START (1.2.5)
        //
        // A userspace restart injects this dylib while imagent - and the rest of the
        // system - are still coming up. Everything below is therefore deferred: during
        // the boot window this plugin performs no work at all beyond being loaded.
        // That keeps its boot profile as close as possible to the detector-only build
        // that was confirmed to reboot cleanly on this device.
        // ---------------------------------------------------------------------
        static const int64_t kKSABootQuietDelaySeconds = 10;
        KSAInfo(@"deferring all plugin work by %llds so the boot sequence is untouched",
                kKSABootQuietDelaySeconds);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      kKSABootQuietDelaySeconds * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                KSAConfig *config = [KSAConfig sharedInstance];
                [config forceReload];

                if (!config.enabled) {
                    KSAInfo(@"plugin disabled (Enabled=false): nothing is polled or alerted");
                    return;
                }

                KSARuntimeStatusReset();
                [[KSAAlertManager sharedInstance] start];

                // 1.3.1 STABLE: the alert engine and the SMS poller, nothing else.
                //
                // Removed on purpose, after on-device failures:
                //   * the IOHID power-button observer - it never delivered a single event,
                //     and every attempt to make it work risked the boot sequence;
                //   * the display/lock Darwin observers - inferring "power button" from the
                //     display is impossible (notifications, taps, raise-to-wake and
                //     auto-dim all produce the same transitions), and lock-state based
                //     stopping is not worth any additional background machinery.
                //
                // What remains has been verified on this device: read-only sms.db polling
                // (since 1.1.x) and the in-process alert engine (vibration + ringer-channel
                // sound, verified working in 1.2.0). An alert ends after its configured
                // SoundDuration / VibrationDuration, or when the "test alert" button is used
                // with the configuration switched off.
                KSAInfo(@"stable build: no HID observer, no display/lock observers, "
                        @"alerts end after their configured duration");
                [[KSASMSDetector sharedInstance] start];
                [[KSASMSWatcher sharedInstance] start];

                KSAInfo(@"detection active: read only SMS database polling every %.1fs "
                        @"(no hooks in imagent)", config.pollInterval);
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
            }
        });
#else
        [[KSASMSDetector sharedInstance] start];

        KSAConfig *config = [KSAConfig sharedInstance];
        if (!config.enabled) {
            KSAInfo(@"plugin disabled (Enabled=false): nothing is installed or polled in imagent");
            return;
        }

        KSAInfo(@"detection: read only SMS database polling every %.1fs (no hooks in imagent)",
                config.pollInterval);
        KSATriggerPost();
        [[KSASMSWatcher sharedInstance] start];
#endif
    }
}
