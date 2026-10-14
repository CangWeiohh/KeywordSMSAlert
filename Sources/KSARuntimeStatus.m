//
//  KSARuntimeStatus.m
//

#import "KSARuntimeStatus.h"
#import "KSACommon.h"
#import <unistd.h>

NSString *KSARuntimeStatusPath(void)
{
    return KSA_RUNTIME_STATUS_PATH;
}

static NSMutableDictionary<NSString *, id> *KSAStatusDictionary(void)
{
    static NSMutableDictionary<NSString *, id> *status = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        status = [NSMutableDictionary dictionary];
    });
    return status;
}

static void KSAWriteStatusLocked(void)
{
    NSMutableDictionary *status = KSAStatusDictionary();
    status[@"UpdatedAt"] = @([[NSDate date] timeIntervalSince1970]);
    status[@"PID"] = @(getpid());
    [status writeToFile:KSARuntimeStatusPath() atomically:YES];
}

void KSARuntimeStatusReset(void)
{
    @synchronized (KSAStatusDictionary()) {
        [KSAStatusDictionary() removeAllObjects];
        KSAStatusDictionary()[@"EngineRunning"] = @YES;
        KSAStatusDictionary()[@"StartedAt"] = @([[NSDate date] timeIntervalSince1970]);
        // Report the process the engine actually lives in. Older builds wrote the
        // literal "launchd-no-springboard" here, which was true only of a design that
        // no longer exists and made every log read misleading.
        KSAStatusDictionary()[@"Architecture"] = @"imagent-in-process";
        KSAStatusDictionary()[@"Process"] = KSAProcessName() ?: @"?";
        KSAStatusDictionary()[@"BundleID"] = KSAProcessBundleIdentifier() ?: @"?";
        KSAWriteStatusLocked();
    }
}

void KSARuntimeStatusUpdate(NSDictionary<NSString *, id> *values)
{
    if (values.count == 0) {
        return;
    }
    @synchronized (KSAStatusDictionary()) {
        [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            if (key.length == 0) {
                return;
            }
            if (value == nil || value == [NSNull null]) {
                [KSAStatusDictionary() removeObjectForKey:key];
            } else {
                KSAStatusDictionary()[key] = value;
            }
        }];
        KSAWriteStatusLocked();
    }
}
