//
//  KSASMSDetector.m
//  KeywordSMSAlert
//

#import "KSASMSDetector.h"
#import "KSACommon.h"
#import "KSAConfig.h"
#import "KSADedupCache.h"
#import "KSALog.h"
#import "KSATrigger.h"

#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - SMSServiceSession dictionary keys

// Dictionary produced by SMSServiceSession (observed by tracing imagent on a real
// device: -[SMSServiceSession _convertCTMessageToDictionary:requiresUpload:]).
// Those short keys are not declared in any public header, which is why the
// detector also supports the header-verified IMDMessageStore path below.
//
//   h  -> sender        (e.g. "1069xxxx" / "+86138xxxx")
//   co -> recipient     (our own number)
//   g  -> message GUID
//   k  -> array of body parts, each { data = <NSData>, type = "text/plain" }
//   m  -> service name  ("sms")
//   w  -> date string
static NSString *const kKSADictSender    = @"h";
static NSString *const kKSADictGUID      = @"g";
static NSString *const kKSADictParts     = @"k";
static NSString *const kKSADictService   = @"m";

// CTMessage.type: 1 == incoming (CTMessageTypeIncoming), 2 == outgoing.
static const NSInteger kKSACTMessageTypeIncoming = 1;

#pragma mark - Small value helpers

/// KVC that never throws (the classes involved are private and may change).
static id KSASafeValueForKey(id object, NSString *key)
{
    if (object == nil || key.length == 0) {
        return nil;
    }
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *KSAStringFromValue(id value)
{
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    if ([value isKindOfClass:[NSAttributedString class]]) {
        return [(NSAttributedString *)value string];
    }
    return nil;
}

/// Decodes a CTMessagePart payload. SMS bodies are normally UTF-8, but UCS-2
/// (UTF-16) and Chinese carrier encodings are also accepted.
static NSString *KSADecodeMessageData(NSData *data)
{
    if (data.length == 0) {
        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length > 0 && [text rangeOfString:@"\uFFFD"].location == NSNotFound) {
        return text;
    }

    text = [[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
    if (text.length > 0 && [text rangeOfString:@"\uFFFD"].location == NSNotFound) {
        return text;
    }

    NSStringEncoding gb18030 = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
    text = [[NSString alloc] initWithData:data encoding:gb18030];
    if (text.length > 0) {
        return text;
    }

    return nil;
}

static NSString *KSADictionarySender(NSDictionary *dictionary)
{
    id sender = dictionary[kKSADictSender];
    if ([sender isKindOfClass:[NSString class]]) {
        return sender;
    }
    if ([sender isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)sender stringValue];
    }
    if (sender != nil) {
        return [sender description];
    }
    return nil;
}

static NSString *KSADictionaryGUID(NSDictionary *dictionary)
{
    id guid = dictionary[kKSADictGUID];
    if ([guid isKindOfClass:[NSString class]]) {
        return guid;
    }
    if ([guid isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)guid stringValue];
    }
    return nil;
}

/// Concatenates all text parts of the message body.
static NSString *KSADictionaryText(NSDictionary *dictionary)
{
    id parts = dictionary[kKSADictParts];
    if (![parts isKindOfClass:[NSArray class]]) {
        return nil;
    }

    NSMutableArray<NSString *> *chunks = [NSMutableArray array];
    for (id part in (NSArray *)parts) {
        if (![part isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        id type = ((NSDictionary *)part)[@"type"];
        if ([type isKindOfClass:[NSString class]]) {
            NSString *lowercaseType = [(NSString *)type lowercaseString];
            // Skip non textual parts (images, vcards, ...) but keep everything that
            // either is explicitly text or carries no type information.
            if ([lowercaseType rangeOfString:@"text"].location == NSNotFound &&
                [lowercaseType rangeOfString:@"plain"].location == NSNotFound) {
                continue;
            }
        }

        NSString *chunk = KSADecodeMessageData(((NSDictionary *)part)[@"data"]);
        if (chunk.length > 0) {
            [chunks addObject:chunk];
        }
    }

    if (chunks.count == 0) {
        return nil;
    }
    return [chunks componentsJoinedByString:@""];
}

/// Text of an IMMessageItem (IMSharedUtilities). Header verified properties:
///   IMMessageItem.body      NSAttributedString
///   IMMessageItem.plainBody NSString
static NSString *KSAMessageItemText(id item)
{
    NSString *text = KSAStringFromValue(KSASafeValueForKey(item, @"plainBody"));
    if (text.length > 0) {
        return text;
    }
    text = KSAStringFromValue(KSASafeValueForKey(item, @"body"));
    if (text.length > 0) {
        return text;
    }
    return KSAStringFromValue(KSASafeValueForKey(item, @"text"));
}

#pragma mark - KSASMSDetector

@implementation KSASMSDetector
{
    KSADedupCache *_dedup;
    NSMutableDictionary<NSString *, NSNumber *> *_hookHitCounts;
    NSLock *_statsLock;
    NSUInteger _receivedCount;
    NSUInteger _matchedCount;
    BOOL _didWarnAboutMissingIncomingFlag;
}

+ (instancetype)sharedInstance
{
    static KSASMSDetector *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KSASMSDetector alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _dedup = [[KSADedupCache alloc] init];
        _hookHitCounts = [NSMutableDictionary dictionary];
        _statsLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)start
{
    [[KSAConfig sharedInstance] forceReload];
    KSALogConfigure([KSAConfig sharedInstance].debugEnabled, [KSAConfig sharedInstance].logToFile);
    KSAInfo(@"SMS detector ready in %@ (%@)", KSAProcessName(), KSAProcessBundleIdentifier());
    KSAInfo(@"%@", [KSAConfig sharedInstance].debugDescription);
}

#pragma mark - Direction / service guards

/// Returns YES when the CTMessage is an incoming message, NO when it is outgoing.
/// When the object exposes no usable flag the message is accepted (and a single
/// debug line explains why).
- (BOOL)_isIncomingMessage:(id)message
{
    if (message == nil) {
        return YES;
    }

    // Preferred: -[CTMessage isIncoming] (BOOL)
    SEL isIncomingSelector = NSSelectorFromString(@"isIncoming");
    if ([message respondsToSelector:isIncomingSelector]) {
        typedef BOOL (*KSABoolReturningIMP)(id, SEL);
        KSABoolReturningIMP implementation = (KSABoolReturningIMP)[message methodForSelector:isIncomingSelector];
        if (implementation != NULL) {
            return implementation(message, isIncomingSelector) ? YES : NO;
        }
    }

    // Fallback: -[CTMessage type] where 1 == CTMessageTypeIncoming.
    SEL typeSelector = NSSelectorFromString(@"type");
    if ([message respondsToSelector:typeSelector]) {
        typedef long (*KSAIntegerReturningIMP)(id, SEL);
        KSAIntegerReturningIMP implementation = (KSAIntegerReturningIMP)[message methodForSelector:typeSelector];
        if (implementation != NULL) {
            long type = implementation(message, typeSelector);
            if (type == kKSACTMessageTypeIncoming) {
                return YES;
            }
            if (type > 0) {
                return NO;
            }
        }
    }

    if (!_didWarnAboutMissingIncomingFlag) {
        _didWarnAboutMissingIncomingFlag = YES;
        KSADebug(@"CTMessage exposes neither isIncoming nor a usable type; accepting the message");
    }
    return YES;
}

/// IMItem.service is "SMS" for text messages and "iMessage" for Apple messages.
/// An unknown service is accepted (the SMSServiceSession path is SMS by design).
- (BOOL)_serviceIsAcceptable:(NSString *)service config:(KSAConfig *)config
{
    if (service.length == 0) {
        return YES;
    }
    if ([service rangeOfString:@"sms" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    if (config.includeIMessage) {
        return YES;
    }
    return NO;
}

#pragma mark - Hook entry points

- (void)handleCTMessage:(id)message
             dictionary:(NSDictionary *)dictionary
                 source:(NSString *)source
{
    @autoreleasepool {
        @try {
            [self _recordHookHit:source];

            if (![dictionary isKindOfClass:[NSDictionary class]]) {
                KSADebug(@"%@ returned no dictionary", source);
                return;
            }
            if (![[KSAConfig sharedInstance] enabled]) {
                KSADebug(@"candidate ignored: plugin disabled");
                return;
            }
            if (![self _isIncomingMessage:message]) {
                KSADebug(@"outgoing message ignored (%@)", source);
                return;
            }

            [self _evaluateText:KSADictionaryText(dictionary)
                         sender:KSADictionarySender(dictionary)
                       identity:KSADictionaryGUID(dictionary)
                        service:KSAStringFromValue(dictionary[kKSADictService])
                         source:source];
        } @catch (NSException *exception) {
            KSAInfo(@"detector exception (ignored): %@", exception.reason);
        }
    }
}

- (void)handleMessageItem:(id)item source:(NSString *)source
{
    @autoreleasepool {
        @try {
            [self _recordHookHit:source];

            if (item == nil) {
                return;
            }

            KSAConfig *config = [KSAConfig sharedInstance];
            [config reloadIfNeeded];
            if (!config.enabled) {
                KSADebug(@"candidate ignored: plugin disabled");
                return;
            }

            // Never react to something we sent ourselves.
            id isFromMe = KSASafeValueForKey(item, @"isFromMe");
            if ([isFromMe isKindOfClass:[NSNumber class]] && [isFromMe boolValue]) {
                KSADebug(@"outgoing message ignored (isFromMe, %@)", source);
                return;
            }

            NSString *service = KSAStringFromValue(KSASafeValueForKey(item, @"service"));
            if (![self _serviceIsAcceptable:service config:config]) {
                KSADebug(@"non-SMS service ignored (%@, service=%@)", source, service);
                return;
            }

            NSString *text = KSAMessageItemText(item);
            if (text.length == 0) {
                KSADebug(@"message without a text body ignored (%@)", source);
                return;
            }

            NSString *sender = KSAStringFromValue(KSASafeValueForKey(item, @"sender"));
            if (sender.length == 0) {
                sender = KSAStringFromValue(KSASafeValueForKey(item, @"handle"));
            }
            NSString *guid = KSAStringFromValue(KSASafeValueForKey(item, @"guid"));

            [self _evaluateText:text
                         sender:sender
                       identity:guid
                        service:service
                         source:source];
        } @catch (NSException *exception) {
            KSAInfo(@"detector exception (ignored): %@", exception.reason);
        }
    }
}

- (void)handlePlainText:(NSString *)text
                 sender:(NSString *)sender
               identity:(NSString *)identity
                service:(NSString *)service
                 source:(NSString *)source
{
    @autoreleasepool {
        @try {
            [self _recordHookHit:source];
            [self _evaluateText:text sender:sender identity:identity service:service source:source];
        } @catch (NSException *exception) {
            KSAInfo(@"detector exception (ignored): %@", exception.reason);
        }
    }
}

#pragma mark - Shared evaluation pipeline

- (void)_evaluateText:(NSString *)text
               sender:(NSString *)sender
             identity:(NSString *)identity
              service:(NSString *)service
               source:(NSString *)source
{
    if (text.length == 0) {
        return;
    }

    KSAConfig *config = [KSAConfig sharedInstance];
    [config reloadIfNeeded];

    if (!config.enabled) {
        return;
    }

    [_statsLock lock];
    _receivedCount++;
    [_statsLock unlock];

    KSAInfo(@"SMS received (service=%@ sender hash=%@ message hash=%@ length=%lu)",
            service ?: @"?",
            KSAHashString(sender) ?: @"-",
            KSAHashString(text) ?: @"-",
            (unsigned long)text.length);
    KSADebugSensitive(@"message body: %@", text);
    KSADebugSensitive(@"sender: %@ guid: %@", sender ?: @"-", identity ?: @"-");

    if ([config shouldIgnoreSender:sender]) {
        KSADebug(@"sender is on the ignore list; not alerting");
        return;
    }

    NSString *matched = [config matchedKeywordInText:text];
    if (matched.length == 0) {
        KSADebug(@"no keyword matched");
        return;
    }

    if (identity.length == 0) {
        // No GUID available: fall back to sender + text. The TTL window still
        // collapses the several callbacks iOS performs for a single message.
        identity = [NSString stringWithFormat:@"%@|%@",
                    KSAHashString(sender) ?: @"-",
                    KSAHashString(text) ?: @"-"];
    }

    if ([_dedup isDuplicateKey:identity window:config.duplicateInterval]) {
        KSAInfo(@"duplicate callback for the same SMS suppressed");
        return;
    }

    [_statsLock lock];
    _matchedCount++;
    [_statsLock unlock];

    KSAInfo(@"keyword matched (keyword hash=%@), notifying alert process",
            KSAHashString(matched));
    KSADebugSensitive(@"matched keyword: %@", matched);

    KSATriggerPost();
}

- (void)_recordHookHit:(NSString *)source
{
    if (source.length == 0) {
        return;
    }
    [_statsLock lock];
    _hookHitCounts[source] = @([_hookHitCounts[source] unsignedIntegerValue] + 1);
    [_statsLock unlock];
}

- (NSString *)diagnostics
{
    [_statsLock lock];
    NSDictionary<NSString *, NSNumber *> *hookHits = [_hookHitCounts copy];
    NSUInteger received = _receivedCount;
    NSUInteger matched = _matchedCount;
    [_statsLock unlock];

    NSMutableArray<NSString *> *hooks = [NSMutableArray array];
    for (NSString *name in hookHits) {
        [hooks addObject:[NSString stringWithFormat:@"%@=%lu", name, (unsigned long)hookHits[name].unsignedIntegerValue]];
    }

    return [NSString stringWithFormat:@"received=%lu matched=%lu hooks[%@]",
            (unsigned long)received, (unsigned long)matched,
            hooks.count ? [hooks componentsJoinedByString:@", "] : @"none"];
}

@end

#pragma mark - On-device diagnostics

static void KSALogSelectorsOfClass(NSString *className, NSArray<NSString *> *requiredSubstrings)
{
    Class clazz = objc_getClass(className.UTF8String);
    if (clazz == Nil) {
        KSAInfo(@"diagnostics: %@ is not loaded in this process", className);
        return;
    }

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(clazz, &methodCount);
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    for (unsigned int index = 0; methods != NULL && index < methodCount; index++) {
        NSString *selectorName = NSStringFromSelector(method_getName(methods[index]));
        NSString *lowercase = selectorName.lowercaseString;
        for (NSString *needle in requiredSubstrings) {
            if ([lowercase rangeOfString:needle.lowercaseString].location != NSNotFound) {
                [candidates addObject:selectorName];
                break;
            }
        }
    }
    if (methods != NULL) {
        free(methods);
    }

    KSAInfo(@"diagnostics: %@ has %u methods; relevant: [%@]",
            className, methodCount,
            candidates.count ? [candidates componentsJoinedByString:@", "] : @"none");
}

void KSALogSMSServiceSessionDiagnostics(void)
{
    KSALogSelectorsOfClass(@"SMSServiceSession",
                           @[ @"sms", @"received", @"convert", @"message", @"dictionary" ]);
    KSALogSelectorsOfClass(@"IMDMessageStore", @[ @"store" ]);
    KSALogSelectorsOfClass(@"IMDServiceSession", @[ @"didreceive" ]);

    // Enumerating every class in the runtime is only done when the user asked for
    // verbose logging.
    if (!KSALogDebugEnabled()) {
        return;
    }

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        return;
    }

    Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
    if (classes == NULL) {
        return;
    }
    classCount = objc_getClassList(classes, classCount);

    NSMutableArray<NSString *> *smsClasses = [NSMutableArray array];
    for (int index = 0; index < classCount; index++) {
        const char *name = class_getName(classes[index]);
        if (name != NULL && strstr(name, "SMS") != NULL) {
            [smsClasses addObject:@(name)];
        }
    }
    free(classes);

    KSADebug(@"diagnostics: runtime classes containing \"SMS\": [%@]",
             smsClasses.count ? [smsClasses componentsJoinedByString:@", "] : @"none");
}
