//
//  KSAPrefsStore.m
//  KeywordSMSAlert
//

#import "KSAPrefsStore.h"
#import "KSAPrefsCommon.h"

NSString *const KSAPropertyKey     = @"ksaKey";
NSString *const KSAPropertyValues  = @"ksaValues";
NSString *const KSAPropertyTitles  = @"ksaTitles";
NSString *const KSAPropertyDefault = @"ksaDefault";

static NSString *const KSAPrefsDomainName = @"com.keyword.smsalert";
static NSString *const KSAReloadNotificationName = @"com.keyword.smsalert.reload";

NSString *KSAPrefsLocalized(NSString *key)
{
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class rootClass = NSClassFromString(@"KSARootListController");
        bundle = rootClass != Nil ? [NSBundle bundleForClass:rootClass] : [NSBundle mainBundle];
    });
    if (bundle == nil) {
        return key;
    }
    return [bundle localizedStringForKey:key value:key table:@"Localizable"];
}

/// Jailbreak root derived from this bundle's own location:
///   <jbroot>/Library/PreferenceBundles/KeywordSMSAlertPrefs.bundle
/// No libroothide dependency is needed for that.
static NSString *KSAPrefsJailbreakRoot(void)
{
    static NSString *root = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundlePath = [NSBundle bundleForClass:NSClassFromString(@"KSARootListController") ?: NSObject.class].bundlePath;
        NSArray<NSString *> *components = bundlePath.pathComponents;
        // ["/", "Library", "PreferenceBundles", "KeywordSMSAlertPrefs.bundle"]
        if (components.count >= 4) {
            root = [NSString pathWithComponents:[components subarrayWithRange:NSMakeRange(0, components.count - 3)]];
        }
        if (root.length == 0) {
            root = @"/";
        }
    });
    return root;
}

/// Same order as KSAConfig in the tweak: the real user preferences file wins, the
/// packaged jbroot copy is the fallback.
static NSArray<NSString *> *KSAPrefsCandidatePaths(void)
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    NSString *rootfsPath = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:
                            [KSAPrefsDomainName stringByAppendingString:@".plist"]];
    [paths addObject:rootfsPath];

    NSString *jbroot = KSAPrefsJailbreakRoot();
    for (NSString *relative in @[ @"/var/mobile/Library/Preferences", @"/Library/Preferences" ]) {
        NSString *candidate = [[jbroot stringByAppendingPathComponent:relative]
                               stringByAppendingPathComponent:
                               [KSAPrefsDomainName stringByAppendingString:@".plist"]];
        if (![paths containsObject:candidate]) {
            [paths addObject:candidate];
        }
    }
    return paths;
}

@implementation KSAPrefsStore
{
    NSMutableDictionary *_values;
}

+ (instancetype)sharedStore
{
    static KSAPrefsStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[KSAPrefsStore alloc] init];
    });
    return store;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self reload];
    }
    return self;
}

- (void)reload
{
    NSDictionary *loaded = nil;
    for (NSString *path in KSAPrefsCandidatePaths()) {
        NSDictionary *dictionary = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([dictionary isKindOfClass:[NSDictionary class]] && dictionary.count > 0) {
            loaded = dictionary;
            break;
        }
    }
    _values = loaded != nil ? [loaded mutableCopy] : [NSMutableDictionary dictionary];
}

#pragma mark - Typed accessors

- (id)_valueForKey:(NSString *)key
{
    id value = _values[key];
    if (value != nil) {
        return value;
    }
    // Case insensitive fallback for hand edited files.
    for (NSString *candidate in _values) {
        if ([[candidate lowercaseString] isEqualToString:key.lowercaseString]) {
            return _values[candidate];
        }
    }
    return nil;
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue
{
    id value = [self _valueForKey:key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value boolValue];
    }
    return defaultValue;
}

- (void)setBool:(BOOL)value forKey:(NSString *)key
{
    _values[key] = @(value);
}

- (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue
{
    id value = [self _valueForKey:key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value doubleValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value doubleValue];
    }
    return defaultValue;
}

- (void)setDouble:(double)value forKey:(NSString *)key
{
    _values[key] = @(value);
}

- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)defaultValue
{
    id value = [self _valueForKey:key];
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }
    return defaultValue;
}

- (void)setString:(NSString *)value forKey:(NSString *)key
{
    if (value.length == 0) {
        [_values removeObjectForKey:key];
        return;
    }
    _values[key] = value;
}

- (NSArray<NSString *> *)arrayForKey:(NSString *)key
{
    id value = [self _valueForKey:key];
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            if ([item isKindOfClass:[NSString class]]) {
                [result addObject:item];
            } else if ([item isKindOfClass:[NSNumber class]]) {
                [result addObject:[item stringValue]];
            }
        }
        return result;
    }
    return @[];
}

- (void)setArray:(NSArray<NSString *> *)value forKey:(NSString *)key
{
    _values[key] = value ?: @[];
}

#pragma mark - Saving

- (BOOL)save
{
    NSArray<NSString *> *paths = KSAPrefsCandidatePaths();
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_values
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:NULL];
    if (data.length == 0) {
        return NO;
    }

    BOOL wroteAny = NO;
    for (NSString *path in paths) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *directory = [path stringByDeletingLastPathComponent];
        if (![fileManager fileExistsAtPath:directory]) {
            continue;
        }
        if ([data writeToFile:path atomically:YES]) {
            wroteAny = YES;
        }
    }

    // Tell the tweak (SpringBoard + imagent) to pick the new values up immediately.
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    if (center != NULL) {
        CFNotificationCenterPostNotification(center,
                                             (__bridge CFNotificationName)KSAReloadNotificationName,
                                             NULL, NULL, true);
    }
    return wroteAny;
}

- (NSString *)activePathDescription
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in KSAPrefsCandidatePaths()) {
        if ([fileManager fileExistsAtPath:path]) {
            return path;
        }
    }
    return KSAPrefsCandidatePaths().firstObject ?: @"?";
}

@end
