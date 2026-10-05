//
//  KSATrigger.m
//  KeywordSMSAlert
//

#import "KSATrigger.h"
#import "KSALog.h"

NSString *const KSATriggerNotificationName = @"com.keyword.smsalert.trigger";
NSString *const KSAReloadNotificationName = @"com.keyword.smsalert.reload";

static void KSATriggerPostNamed(NSString *name)
{
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    if (center == NULL) {
        return;
    }
    CFNotificationCenterPostNotification(center,
                                         (__bridge CFNotificationName)name,
                                         NULL,
                                         NULL,
                                         true);
}

void KSATriggerPost(void)
{
    KSATriggerPostNamed(KSATriggerNotificationName);
}

void KSAReloadPost(void)
{
    KSATriggerPostNamed(KSAReloadNotificationName);
}

#pragma mark - Observer bookkeeping

/// CFNotificationCenterAddObserver does not retain the observer pointer, so every
/// registered observer is kept alive here for the lifetime of the process.
@interface KSAObserverToken : NSObject
@property (nonatomic, copy) KSANotificationHandler handler;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@end

@implementation KSAObserverToken
@end

static NSMutableArray<KSAObserverToken *> *KSATokens(void)
{
    static NSMutableArray<KSAObserverToken *> *tokens = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = [NSMutableArray array];
    });
    return tokens;
}

static void KSANotificationCallback(CFNotificationCenterRef center,
                                    void *observer,
                                    CFNotificationName name,
                                    const void *object,
                                    CFDictionaryRef userInfo)
{
    KSAObserverToken *token = (__bridge KSAObserverToken *)observer;
    KSANotificationHandler handler = token.handler;
    if (handler == nil) {
        return;
    }

    dispatch_queue_t queue = token.queue ?: dispatch_get_main_queue();
    // Never run alert engine work on the notifying (possibly system daemon) thread.
    dispatch_async(queue, handler);
}

static void KSANotificationObserve(NSString *name, dispatch_queue_t queue, KSANotificationHandler handler)
{
    if (name.length == 0 || handler == nil) {
        return;
    }

    KSAObserverToken *token = [[KSAObserverToken alloc] init];
    token.handler = handler;
    token.queue = queue ?: dispatch_get_main_queue();
    token.name = name;

    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    if (center == NULL) {
        return;
    }

    @synchronized (KSATokens()) {
        [KSATokens() addObject:token];
    }

    CFNotificationCenterAddObserver(center,
                                    (__bridge const void *)token,
                                    KSANotificationCallback,
                                    (__bridge CFStringRef)name,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    KSADebug(@"observing notification %@", name);
}

void KSATriggerObserve(dispatch_queue_t queue, KSANotificationHandler handler)
{
    KSANotificationObserve(KSATriggerNotificationName, queue, handler);
}

void KSAReloadObserve(dispatch_queue_t queue, KSANotificationHandler handler)
{
    KSANotificationObserve(KSAReloadNotificationName, queue, handler);
}
