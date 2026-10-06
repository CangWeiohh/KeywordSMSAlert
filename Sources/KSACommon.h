//
//  KSACommon.h
//  KeywordSMSAlert
//
//  Shared helpers: jailbreak path handling, process identification, hashing.
//
//  Target environment: iOS 15.4.1 (arm64e) + Dopamine RootHide 2.4.9.27 (roothide)
//
//  IMPORTANT (roothide):
//    roothide does NOT install into the fixed path /var/jb. The jailbreak root
//    ("jbroot") has a random per-jailbreak path. All jailbreak files must be
//    addressed through the roothide API:
//
//        jbroot("/Library/KeywordSMSAlert/alert.caf")
//          -> "/private/var/containers/Bundle/Application/.jbroot-XXXX/Library/..."
//
//    Always build jailbreak paths as if "/" were the jailbreak root, then pass
//    them through KSAPathInJB().
//

#ifndef KSA_COMMON_H
#define KSA_COMMON_H

#import <Foundation/Foundation.h>

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#include <roothide.h>
#else
#include <rootless.h>
#endif

/// Convert a jbroot-based path (e.g. @"/Library/KeywordSMSAlert/alert.caf") into
/// a real filesystem path on the current jailbreak. Safe to call from any process.
FOUNDATION_EXPORT NSString *KSAPathInJB(NSString *jbrootBasedPath);

/// Returns the first path from `paths` that exists on disk, or nil.
FOUNDATION_EXPORT NSString *KSAFirstExistingPath(NSArray<NSString *> *paths);

/// Bundle identifier of the host process ("com.apple.springboard", "com.apple.imagent", ...)
FOUNDATION_EXPORT NSString *KSAProcessBundleIdentifier(void);

/// Executable name of the host process ("SpringBoard", "imagent", ...)
FOUNDATION_EXPORT NSString *KSAProcessName(void);

FOUNDATION_EXPORT BOOL KSAIsSpringBoardProcess(void);
FOUNDATION_EXPORT BOOL KSAIsIMAgentProcess(void);

/// Emergency kill switch (see README "应急开关").
///
/// The marker file lives in the REAL rootfs at
/// /var/mobile/Library/Preferences/com.keyword.smsalert.safemode
/// (the jailbreak root copy is accepted too, for people who drop it in jbroot).
/// While it exists:
///   * SpringBoard installs NO hook at all (no button watcher, no lock watcher),
///   * the alert engine still runs and still logs, but the power button cannot
///     stop an alert, because that is what the hooks are for.
/// This exists so a black screen / hang can be bisected without uninstalling:
///   ssh root@device 'touch /var/mobile/Library/Preferences/com.keyword.smsalert.safemode'
/// then restart userspace (or `killall -9 SpringBoard`).
FOUNDATION_EXPORT NSString *KSASafeModeMarkerPath(void);
FOUNDATION_EXPORT BOOL KSASafeModeEnabled(void);

/// Stable short hash (FNV-1a 64) of a string, used for privacy-preserving logs.
/// Returns nil for nil input. Never used for security purposes.
FOUNDATION_EXPORT NSString *KSAHashString(NSString *string);

/// Monotonic-ish wall clock helper.
FOUNDATION_EXPORT NSTimeInterval KSANow(void);

/// Best effort "is the main thread's runloop alive" guard used before scheduling work.
FOUNDATION_EXPORT void KSADispatchAsync(dispatch_queue_t queue, dispatch_block_t block);

#endif /* KSA_COMMON_H */
