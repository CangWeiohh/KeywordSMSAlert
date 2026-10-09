//
//  KSARuntimeStatus.m
//

#import "KSARuntimeStatus.h"
#import <unistd.h>

NSString *KSARuntimeStatusPath(void)
{
    return @"/var/mobile/Library/Preferences/com.keyword.smsalert.runtime.plist";
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
        KSAStatusDictionary()[@"DaemonRunning"] = @YES;
        KSAStatusDictionary()[@"StartedAt"] = @([[NSDate date] timeIntervalSince1970]);
        KSAStatusDictionary()[@"Architecture"] = @"launchd-no-springboard";
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
