//
//  KSADedupCache.m
//  KeywordSMSAlert
//

#import "KSADedupCache.h"
#import "KSACommon.h"
#import "KSALog.h"

static const NSUInteger kKSADedupMaxEntries = 128;
static const NSTimeInterval kKSADedupPruneFloor = 60.0;

@implementation KSADedupCache
{
    NSMutableDictionary<NSString *, NSNumber *> *_timestamps;
    NSLock *_lock;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _timestamps = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (BOOL)isDuplicateKey:(NSString *)key window:(NSTimeInterval)window
{
    if (key.length == 0) {
        return NO;
    }

    NSTimeInterval now = KSANow();

    [_lock lock];
    NSNumber *previous = _timestamps[key];
    BOOL duplicate = NO;
    if (previous != nil) {
        NSTimeInterval delta = now - previous.doubleValue;
        // A zero (or negative) window means "always suppress the same key while
        // it is remembered".
        duplicate = (window <= 0.0) ? (delta >= 0.0) : (delta < window);
    }

    if (!duplicate) {
        _timestamps[key] = @(now);
        if (_timestamps.count > kKSADedupMaxEntries) {
            [self _pruneLockedWithWindow:MAX(window, kKSADedupPruneFloor) now:now];
        }
    }

    NSUInteger remembered = _timestamps.count;
    [_lock unlock];

    if (duplicate) {
        KSADebug(@"duplicate event suppressed (key %@, %lu remembered)",
                 KSAHashString(key), (unsigned long)remembered);
    }

    return duplicate;
}

- (void)_pruneLockedWithWindow:(NSTimeInterval)window now:(NSTimeInterval)now
{
    NSMutableArray<NSString *> *expired = [NSMutableArray array];
    for (NSString *key in _timestamps) {
        if ((now - _timestamps[key].doubleValue) > window) {
            [expired addObject:key];
        }
    }
    [_timestamps removeObjectsForKeys:expired];

    if (_timestamps.count > kKSADedupMaxEntries) {
        // Still too large: drop the oldest half.
        NSArray<NSString *> *sorted = [_timestamps keysSortedByValueUsingComparator:
                                       ^NSComparisonResult(NSNumber *lhs, NSNumber *rhs) {
            return [lhs compare:rhs];
        }];
        NSUInteger removeCount = sorted.count / 2;
        for (NSUInteger index = 0; index < removeCount; index++) {
            [_timestamps removeObjectForKey:sorted[index]];
        }
    }
}

- (void)reset
{
    [_lock lock];
    [_timestamps removeAllObjects];
    [_lock unlock];
}

@end
