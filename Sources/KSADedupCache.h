//
//  KSADedupCache.h
//  KeywordSMSAlert
//
//  Small, allocation friendly de-duplication cache.
//
//  iOS may surface the same incoming SMS through more than one hook (for example
//  "_convertCTMessageToDictionary:requiresUpload:" and
//  "_receivedSMSDictionary:requiresUpload:isBeingReplayed:" are both called for a
//  single received message). Without de-duplication the user would get several
//  overlapping alerts for one SMS.
//
//  The cache keys on the best identity available (message GUID when the daemon
//  exposes one, otherwise sender hash + text hash + a coarse time bucket) and
//  suppresses repeats inside a configurable TTL window (DuplicateInterval).
//

#ifndef KSA_DEDUP_CACHE_H
#define KSA_DEDUP_CACHE_H

#import <Foundation/Foundation.h>

@interface KSADedupCache : NSObject

/// Returns YES when `key` was seen less than `window` seconds ago.
/// Thread safe. A nil/empty key is never suppressed.
- (BOOL)isDuplicateKey:(NSString *)key window:(NSTimeInterval)window;

/// Drops all remembered keys.
- (void)reset;

@end

#endif /* KSA_DEDUP_CACHE_H */
