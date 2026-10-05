//
//  KSASMSWatcher.h
//  KeywordSMSAlert
//
//  Hook free SMS detection: polls the SMS database READ ONLY on a private serial queue.
//
//  Why: hooking inside imagent is the most direct route but it is also the route that
//  can break SMS reception if a private method changes shape. This watcher never
//  installs a hook, never writes to the database and never touches the message
//  pipeline, so SMS reception cannot be affected by it. The price is a small latency
//  (PollInterval, default 1.5 s) instead of "instant".
//

#ifndef KSA_SMS_WATCHER_H
#define KSA_SMS_WATCHER_H

#import <Foundation/Foundation.h>

@interface KSASMSWatcher : NSObject

+ (instancetype)sharedInstance;

/// Starts polling (idempotent). Only used when DetectionMode = db.
- (void)start;

/// Stops polling and closes the database.
- (void)stop;

@end

#endif /* KSA_SMS_WATCHER_H */
