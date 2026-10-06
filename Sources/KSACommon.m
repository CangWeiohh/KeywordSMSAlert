//
//  KSACommon.m
//  KeywordSMSAlert
//

#import "KSACommon.h"

NSString *KSAPathInJB(NSString *jbrootBasedPath)
{
    if (jbrootBasedPath.length == 0) {
        return nil;
    }

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    // roothide: jbroot() converts a jbroot-based path to the rootfs path of the
    // (randomly named) jailbreak root. Implemented in libroothide.dylib, which is
    // resolved through "@loader_path/.jbroot/usr/lib/libroothide.dylib".
    return jbroot(jbrootBasedPath);
#else
    return ROOT_PATH_NS(jbrootBasedPath);
#endif
}

NSString *KSAFirstExistingPath(NSArray<NSString *> *paths)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if (path.length == 0) {
            continue;
        }
        if ([fm fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

NSString *KSAProcessBundleIdentifier(void)
{
    static NSString *bundleIdentifier = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // mainBundle is the host app bundle: SpringBoard.app / imagent.app / MobileSMS.app
        bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
        if (bundleIdentifier.length == 0) {
            // Fallback: read the executable's neighbouring Info.plist
            NSString *execPath = [NSBundle mainBundle].executablePath;
            if (execPath.length > 0) {
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                      [[execPath stringByDeletingLastPathComponent]
                                       stringByAppendingPathComponent:@"Info.plist"]];
                bundleIdentifier = info[@"CFBundleIdentifier"];
            }
        }
    });
    return bundleIdentifier;
}

NSString *KSAProcessName(void)
{
    static NSString *processName = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        processName = [NSProcessInfo processInfo].processName;
        if (processName.length == 0) {
            processName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"];
        }
    });
    return processName;
}

BOOL KSAIsSpringBoardProcess(void)
{
    static BOOL isSpringBoard = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *identifier = KSAProcessBundleIdentifier();
        isSpringBoard = [identifier isEqualToString:@"com.apple.springboard"] ||
                        [KSAProcessName() isEqualToString:@"SpringBoard"];
    });
    return isSpringBoard;
}

BOOL KSAIsIMAgentProcess(void)
{
    static BOOL isIMAgent = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *identifier = KSAProcessBundleIdentifier();
        isIMAgent = [identifier isEqualToString:@"com.apple.imagent"] ||
                    [KSAProcessName() isEqualToString:@"imagent"];
    });
    return isIMAgent;
}

NSString *KSAHashString(NSString *string)
{
    if (string == nil) {
        return nil;
    }

    const char *bytes = string.UTF8String;
    if (bytes == NULL) {
        return nil;
    }

    // FNV-1a 64 bit. Only used to keep logs free of message contents.
    uint64_t hash = 1469598103934665603ULL;
    for (const unsigned char *p = (const unsigned char *)bytes; *p != 0; p++) {
        hash ^= (uint64_t)(*p);
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
}

NSTimeInterval KSANow(void)
{
    return [NSDate date].timeIntervalSince1970;
}

void KSADispatchAsync(dispatch_queue_t queue, dispatch_block_t block)
{
    if (block == nil) {
        return;
    }
    if (queue == NULL) {
        queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    }
    dispatch_async(queue, block);
}

#pragma mark - Emergency kill switch

NSString *KSASafeModeMarkerPath(void)
{
    // Deliberately the REAL rootfs path: it must be reachable by ssh/dpkg even when
    // the jailbreak root changes, and SpringBoard runs as mobile which owns it.
    return @"/var/mobile/Library/Preferences/com.keyword.smsalert.safemode";
}

BOOL KSASafeModeEnabled(void)
{
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:KSASafeModeMarkerPath()]) {
            enabled = YES;
        }
        NSString *jailbreakCopy = KSAPathInJB(@"/var/mobile/Library/Preferences/com.keyword.smsalert.safemode");
        if (!enabled && jailbreakCopy.length > 0 && [fileManager fileExistsAtPath:jailbreakCopy]) {
            enabled = YES;
        }
    });
    return enabled;
}

