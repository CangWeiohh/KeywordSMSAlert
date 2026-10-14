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
#import <mach/mach.h>
#import <unistd.h>

#import "KSACommon.h"
#import "KSAConfig.h"
#import "KSALog.h"
#import "KSASMSDetector.h"
#import "KSASMSWatcher.h"
#import "KSATrigger.h"

#ifdef KSA_ALERT_IN_DETECTOR
#import "KSAAlertManager.h"
#import "KSARuntimeStatus.h"
#endif

/// How long the plugin stays completely idle after the dylib is loaded.
///
/// A userspace restart injects this dylib while imagent - and the rest of the system -
/// are still coming up. Nothing below the constructor runs during that window.
static const int64_t kKSABootQuietDelaySeconds = 10;

/// Low frequency resource sampling. Only used when file logging is on, so a user who
/// never enables the log pays nothing at all.
static const int64_t kKSAResourceSampleIntervalSeconds = 300;

#ifdef KSA_ALERT_IN_DETECTOR
/// Resident size in bytes, for the low-frequency resource line.
static unsigned long long KSAResidentBytes(void)
{
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (unsigned long long)info.resident_size;
}

/// Starts the optional low-frequency diagnostics. Does nothing unless the user turned
/// on file logging (or debug logging), so the default configuration adds no wake-ups.
static void KSAStartResourceSamplingIfEnabled(void)
{
    KSAConfig *config = [KSAConfig sharedInstance];
    if (!config.logToFile && !config.debugEnabled) {
        return;
    }

    KSAInfo(@"low frequency resource sampling enabled (every %llds)",
            kKSAResourceSampleIntervalSeconds);

    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (timer == NULL) {
        return;
    }
    uint64_t interval = (uint64_t)kKSAResourceSampleIntervalSeconds * NSEC_PER_SEC;
    // Wide leeway: this is a diagnostic sample, not a deadline.
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval,
                              (uint64_t)(30 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            KSAInfo(@"resource sample: resident=%.1fMB uptime=%.0fs process=%@ pid=%d",
                    KSAResidentBytes() / (1024.0 * 1024.0),
                    [[NSProcessInfo processInfo] systemUptime],
                    KSAProcessName() ?: @"?", getpid());
        }
    });
    dispatch_resume(timer);
}
#endif

%ctor
{
    // The constructor runs inside imagent's dyld load window. Anything thrown here would
    // abort the load of the whole daemon, so every path is guarded and the function has
    // exactly one job: decide whether to schedule the deferred start.
    @autoreleasepool {
        @try {
            if (!KSAIsIMAgentProcess()) {
                KSADebug(@"detector dylib loaded outside imagent (%@); idle",
                         KSAProcessBundleIdentifier() ?: @"?");
                return;
            }

            KSAInfo(@"detector %@ loaded into %@ (pid %d) - hook free, no SpringBoard code",
                    KSAVersionString() ?: @"?", KSAProcessName(), getpid());

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
            KSAInfo(@"deferring all plugin work by %llds so the boot sequence is untouched",
                    kKSABootQuietDelaySeconds);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          kKSABootQuietDelaySeconds * NSEC_PER_SEC),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool {
                    @try {
                        // Emergency kill switch: the marker file makes the plugin inert
                        // without touching the configuration file.
                        if (KSASafeModeEnabled()) {
                            KSAInfo(@"safe mode is ON (%@): the plugin stays inert",
                                    KSASafeModeMarkerPath());
                            return;
                        }

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
                        //   * the IOHID power-button observer - it never delivered a single
                        //     event, and every attempt to make it work risked the boot
                        //     sequence;
                        //   * the display/lock Darwin observers - inferring "power button"
                        //     from the display is impossible (notifications, taps,
                        //     raise-to-wake and auto-dim all produce the same transitions),
                        //     and every rule that was added to fix one misfire produced the
                        //     next one;
                        //   * any SpringBoard injection whatsoever - it turned CallAssist's
                        //     1s boot hiccup into a permanent black screen.
                        //
                        // An alert now ends after its configured SoundDuration /
                        // VibrationDuration, or as soon as the message that started it is
                        // read (KSASMSWatcher watches that ROWID's is_read flag).
                        KSAInfo(@"stable build: no HID observer, no display/lock observers, "
                                @"no hooks; stop source = read receipt");
                        [[KSASMSDetector sharedInstance] start];
                        [[KSASMSWatcher sharedInstance] start];

                        KSAInfo(@"detection active: read only SMS database polling every %.1fs "
                                @"(no hooks in imagent)", config.pollInterval);
                        KSAInfo(@"alert engine hosted in imagent (vibration + alert channel sound)");

                        KSAStartResourceSamplingIfEnabled();

                        if (config.testAlertOnLoad) {
                            KSAInfo(@"TestAlertOnLoad is enabled: firing a test alert in 3 seconds");
                            // Deliberately not the main queue: the alert engine has its own
                            // queue and must not depend on imagent's main run loop being free.
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                @autoreleasepool {
                                    KSAMatchEvent *event = [[KSAMatchEvent alloc] init];
                                    event.source = @"imagent self test";
                                    event.text = @"KeywordSMSAlert self test";
                                    event.keyword = @"self test";
                                    [[KSAAlertManager sharedInstance] handleMatchEvent:event];
                                }
                            });
                        }
                    } @catch (NSException *exception) {
                        KSAInfo(@"deferred startup failed (%@); the plugin stays inert", exception.reason);
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
        } @catch (NSException *exception) {
            // Never let the plugin take imagent down with it during dyld load.
            KSADebug(@"detector constructor failed (%@); continuing without the plugin",
                     exception.reason);
        }
    }
}
