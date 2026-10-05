//
//  KSAConfig.m
//  KeywordSMSAlert
//

#import "KSAConfig.h"
#import "KSACommon.h"
#import "KSALog.h"

// --- normalised snapshot keys -------------------------------------------------
static NSString *const kKeyEnabled           = @"enable";
static NSString *const kKeyKeywords          = @"keywords";
static NSString *const kKeyMatchMode         = @"matchMode";
static NSString *const kKeyCaseInsensitive   = @"caseInsensitive";
static NSString *const kKeyMinMessageLength  = @"minMessageLength";
static NSString *const kKeyIgnoreSenders     = @"ignoreSenders";
static NSString *const kKeyIncludeIMessage   = @"includeIMessage";
static NSString *const kKeyAlertMode         = @"alertMode";
static NSString *const kKeyVibrationEnabled  = @"vibrationEnabled";
static NSString *const kKeyVibrationDuration = @"vibrationDuration";
static NSString *const kKeyVibrationInterval = @"vibrationInterval";
static NSString *const kKeySoundEnabled      = @"soundEnabled";
static NSString *const kKeySoundDuration     = @"soundDuration";
static NSString *const kKeySoundVolume       = @"soundVolume";
static NSString *const kKeySoundLoop         = @"soundLoop";
static NSString *const kKeySoundFile         = @"soundFile";
static NSString *const kKeySoundChannel      = @"soundChannel";
static NSString *const kKeySoundRepeatInterval = @"soundRepeatInterval";
static NSString *const kKeyDuplicateInterval = @"duplicateInterval";
static NSString *const kKeyOnNewMatchedSMS   = @"onNewMatchedSMS";
static NSString *const kKeyDebugEnabled      = @"debugEnabled";
static NSString *const kKeyLogToFile         = @"logToFile";
static NSString *const kKeyTestAlertOnLoad   = @"testAlertOnLoad";
static NSString *const kKeyMessageStoreBackstop    = @"messageStoreBackstop";
static NSString *const kKeyServiceSessionBackstop  = @"serviceSessionBackstop";

static const NSTimeInterval kKSAReloadThrottle = 2.0;

// --- small value coercion helpers ---------------------------------------------
static id KSARawValue(NSDictionary *raw, NSString *key)
{
    id value = raw[key];
    if (value == nil && key.length > 0) {
        // Accept lower case variants so a hand written plist is forgiving.
        NSString *lower = [key lowercaseString];
        for (NSString *candidate in raw) {
            if ([candidate isKindOfClass:[NSString class]] &&
                [[candidate lowercaseString] isEqualToString:lower]) {
                value = raw[candidate];
                break;
            }
        }
    }
    return value;
}

static BOOL KSABoolValue(NSDictionary *raw, NSString *key, BOOL fallback)
{
    id value = KSARawValue(raw, key);
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = [(NSString *)value lowercaseString];
        if ([string isEqualToString:@"1"] || [string isEqualToString:@"yes"] ||
            [string isEqualToString:@"true"] || [string isEqualToString:@"on"]) {
            return YES;
        }
        if ([string isEqualToString:@"0"] || [string isEqualToString:@"no"] ||
            [string isEqualToString:@"false"] || [string isEqualToString:@"off"]) {
            return NO;
        }
    }
    return fallback;
}

static double KSADoubleValue(NSDictionary *raw, NSString *key, double fallback)
{
    id value = KSARawValue(raw, key);
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value doubleValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value doubleValue];
    }
    return fallback;
}

static NSUInteger KSAUnsignedValue(NSDictionary *raw, NSString *key, NSUInteger fallback)
{
    id value = KSARawValue(raw, key);
    if ([value isKindOfClass:[NSNumber class]]) {
        NSInteger signedValue = [value integerValue];
        return signedValue < 0 ? fallback : (NSUInteger)signedValue;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSInteger signedValue = [(NSString *)value integerValue];
        return signedValue < 0 ? fallback : (NSUInteger)signedValue;
    }
    return fallback;
}

static NSString *KSAStringValue(NSDictionary *raw, NSString *key, NSString *fallback)
{
    id value = KSARawValue(raw, key);
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return [(NSString *)value stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }
    return fallback;
}

static NSArray<NSString *> *KSAStringArrayValue(NSDictionary *raw, NSString *key)
{
    id value = KSARawValue(raw, key);
    if (value == nil) {
        return @[];
    }
    if ([value isKindOfClass:[NSString class]]) {
        value = @[ value ];
    }
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        NSString *string = nil;
        if ([item isKindOfClass:[NSString class]]) {
            string = item;
        } else if ([item isKindOfClass:[NSNumber class]]) {
            string = [item stringValue];
        }
        if (string == nil) {
            continue;
        }
        string = [string stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (string.length > 0) {
            [result addObject:string];
        }
    }
    return result;
}

static double KSAClamp(double value, double minimum, double maximum)
{
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

// --- file candidates ----------------------------------------------------------
static NSArray<NSString *> *KSAConfigCandidatePaths(void)
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    // Real (jailbreak independent) location FIRST: this is the file the Settings pane
    // writes and the one users can edit with Filza, so it must take precedence over the
    // packaged default that dpkg dropped into the jailbreak root.
    [paths addObject:@"/var/mobile/Library/Preferences/com.keyword.smsalert.plist"];

    NSString *inJB = KSAPathInJB(@"/var/mobile/Library/Preferences/com.keyword.smsalert.plist");
    if (inJB.length > 0 && ![paths containsObject:inJB]) {
        [paths addObject:inJB];
    }

    NSString *inLib = KSAPathInJB(@"/Library/Preferences/com.keyword.smsalert.plist");
    if (inLib.length > 0) {
        [paths addObject:inLib];
    }

    return paths;
}

static NSArray<NSString *> *KSAKeywordsFileCandidatePaths(void)
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *inJB = KSAPathInJB(@"/Library/KeywordSMSAlert/keywords.txt");
    if (inJB.length > 0) {
        [paths addObject:inJB];
    }
    [paths addObject:@"/var/mobile/Library/KeywordSMSAlert/keywords.txt"];
    return paths;
}

// --- parsing ------------------------------------------------------------------
static NSDictionary *KSAParseConfigData(NSData *data)
{
    if (data.length == 0) {
        return nil;
    }

    NSError *error = nil;
    id object = [NSPropertyListSerialization propertyListWithData:data
                                                          options:0
                                                           format:NULL
                                                            error:&error];

    if (object == nil) {
        object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    }

    if (object == nil) {
        // iOS cannot read the "OpenStep" ASCII plist syntax
        // ({ Enabled = 1; Keywords = ( "验证码" ); }). Report it clearly instead of
        // silently falling back to defaults.
        const unsigned char *bytes = data.bytes;
        NSUInteger length = data.length;
        NSUInteger index = 0;
        while (index < length && (bytes[index] == ' ' || bytes[index] == '\n' ||
                                  bytes[index] == '\r' || bytes[index] == '\t')) {
            index++;
        }
        if (index < length && (bytes[index] == '{' || bytes[index] == '(')) {
            KSAInfo(@"config looks like an OpenStep-format plist, which iOS cannot parse; "
                     "save it as an XML plist (or JSON), or simply use keywords.txt");
        }
        return nil;
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        return object;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        // A bare array is interpreted as the keyword list.
        return @{ @"Keywords": object };
    }
    return nil;
}

static NSArray<NSString *> *KSAReadKeywordsFile(NSString *path)
{
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (contents.length == 0) {
        return nil;
    }

    NSMutableArray<NSString *> *keywords = [NSMutableArray array];
    for (NSString *line in [contents componentsSeparatedByCharactersInSet:
                            [NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) {
            continue;
        }
        [keywords addObject:trimmed];
    }
    return keywords;
}

@interface KSAConfig ()
{
    NSDictionary *_snapshot;
    NSString *_activePath;
    NSTimeInterval _lastReload;
    BOOL _didLogLoad;
}
@end

@implementation KSAConfig

+ (instancetype)sharedInstance
{
    static KSAConfig *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KSAConfig alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _snapshot = [self.class _buildSnapshotFromRaw:nil activePath:nil];
        _activePath = nil;
        _lastReload = 0;
    }
    return self;
}

// --- reload ------------------------------------------------------------------
- (void)reloadIfNeeded
{
    NSTimeInterval now = KSANow();
    if (_lastReload > 0 && (now - _lastReload) < kKSAReloadThrottle) {
        return;
    }
    [self forceReload];
}

- (void)forceReload
{
    [self forceReloadFromPath:nil];
}

- (void)forceReloadFromPath:(NSString *)explicitPath
{
    @try {
        NSString *path = explicitPath.length > 0 ? explicitPath
                                                 : KSAFirstExistingPath(KSAConfigCandidatePaths());
        NSDictionary *raw = nil;

        if (path != nil) {
            NSData *data = [NSData dataWithContentsOfFile:path];
            raw = KSAParseConfigData(data);
            if (raw == nil) {
                KSAInfo(@"config file could not be parsed: %@", path.lastPathComponent);
            }
        }

        NSDictionary *snapshot = [self.class _buildSnapshotFromRaw:raw activePath:path];

        // keywords.txt (one keyword per line) overrides the Keywords array.
        // It only takes part in automatic discovery, never for an explicit path.
        NSString *keywordsFile = explicitPath.length > 0
            ? nil
            : KSAFirstExistingPath(KSAKeywordsFileCandidatePaths());
        if (keywordsFile != nil) {
            NSArray<NSString *> *keywords = KSAReadKeywordsFile(keywordsFile);
            if (keywords.count > 0) {
                NSMutableDictionary *mutable = [snapshot mutableCopy];
                mutable[kKeyKeywords] = keywords;
                snapshot = mutable;
            }
        }

        @synchronized (self) {
            _snapshot = snapshot;
            _activePath = path;
            _lastReload = KSANow();
        }

        KSALogConfigure([snapshot[kKeyDebugEnabled] boolValue],
                        [snapshot[kKeyLogToFile] boolValue]);

        if (!_didLogLoad) {
            _didLogLoad = YES;
            KSAInfo(@"configuration loaded (source: %@)", path ?: @"built-in defaults");
            KSAInfo(@"%@", self.debugDescription);
            KSAInfo(@"alert sound: %@", self.resolvedSoundPath ?: @"(system default sound id)");
        } else {
            KSADebug(@"configuration reloaded from %@", path ?: @"built-in defaults");
        }
    } @catch (__unused NSException *exception) {
        KSAInfo(@"configuration reload failed; keeping previous values");
    }
}

+ (NSDictionary *)_buildSnapshotFromRaw:(NSDictionary *)raw activePath:(NSString *)path
{
    raw = [raw isKindOfClass:[NSDictionary class]] ? raw : @{};

    // An explicitly empty keyword list means "never trigger" (requirement: 关键词为空时不触发);
    // only a configuration that does not mention Keywords at all gets the built-in default.
    NSArray<NSString *> *keywords = nil;
    BOOL keywordsSpecified = NO;
    for (NSString *key in raw) {
        if ([key isKindOfClass:[NSString class]] &&
            [[key lowercaseString] isEqualToString:@"keywords"]) {
            keywordsSpecified = YES;
            break;
        }
    }
    if (keywordsSpecified) {
        keywords = KSAStringArrayValue(raw, @"Keywords");
    } else {
        keywords = @[ @"验证码" ];
    }

    KSAMatchMode matchMode = KSAMatchModeContains;
    id matchModeValue = KSARawValue(raw, @"MatchMode");
    if ([matchModeValue isKindOfClass:[NSNumber class]]) {
        matchMode = (KSAMatchMode)[matchModeValue integerValue];
    } else if ([matchModeValue isKindOfClass:[NSString class]]) {
        NSString *string = [(NSString *)matchModeValue lowercaseString];
        if ([string isEqualToString:@"exact"] || [string isEqualToString:@"full"]) {
            matchMode = KSAMatchModeExact;
        } else if ([string isEqualToString:@"prefix"] || [string isEqualToString:@"startswith"]) {
            matchMode = KSAMatchModePrefix;
        } else {
            matchMode = KSAMatchModeContains;
        }
    }
    if (matchMode < KSAMatchModeContains || matchMode > KSAMatchModePrefix) {
        matchMode = KSAMatchModeContains;
    }

    BOOL vibrationConfigured = KSABoolValue(raw, @"VibrationEnabled", YES);
    BOOL soundConfigured = KSABoolValue(raw, @"SoundEnabled", YES);

    NSInteger alertMode = -1;
    id alertModeValue = KSARawValue(raw, @"AlertMode");
    if ([alertModeValue isKindOfClass:[NSNumber class]]) {
        alertMode = [alertModeValue integerValue];
    } else if ([alertModeValue isKindOfClass:[NSString class]]) {
        alertMode = [(NSString *)alertModeValue integerValue];
    }
    if (alertMode < 0 || alertMode > 3) {
        alertMode = (vibrationConfigured ? 1 : 0) | (soundConfigured ? 2 : 0);
    }

    BOOL vibrationEnabled = ((alertMode == 1) || (alertMode == 3)) && vibrationConfigured;
    BOOL soundEnabled = ((alertMode == 2) || (alertMode == 3)) && soundConfigured;

    KSAOnNewMatchedSMS policy = KSAOnNewMatchedSMSRestart;
    id policyValue = KSARawValue(raw, @"OnNewMatchedSMS");
    if ([policyValue isKindOfClass:[NSNumber class]]) {
        policy = (KSAOnNewMatchedSMS)[policyValue integerValue];
    } else if ([policyValue isKindOfClass:[NSString class]]) {
        NSString *string = [(NSString *)policyValue lowercaseString];
        if ([string isEqualToString:@"ignore"]) {
            policy = KSAOnNewMatchedSMSIgnore;
        } else if ([string isEqualToString:@"queue"]) {
            policy = KSAOnNewMatchedSMSQueue;
        } else {
            policy = KSAOnNewMatchedSMSRestart;
        }
    }
    if (policy < KSAOnNewMatchedSMSRestart || policy > KSAOnNewMatchedSMSQueue) {
        policy = KSAOnNewMatchedSMSRestart;
    }

    return @{
        kKeyEnabled:           @(KSABoolValue(raw, @"Enabled", YES)),
        kKeyKeywords:          keywords,
        kKeyMatchMode:         @(matchMode),
        kKeyCaseInsensitive:   @(KSABoolValue(raw, @"CaseInsensitive", YES)),
        kKeyMinMessageLength:  @(KSAUnsignedValue(raw, @"MinMessageLength", 1)),
        kKeyIgnoreSenders:     KSAStringArrayValue(raw, @"IgnoreSenders"),
        kKeyIncludeIMessage:   @(KSABoolValue(raw, @"IncludeIMessage", NO)),

        kKeyAlertMode:         @(alertMode),
        kKeyVibrationEnabled:  @(vibrationEnabled),
        kKeyVibrationDuration: @(KSAClamp(KSADoubleValue(raw, @"VibrationDuration", 5.0), 0.1, 60.0)),
        kKeyVibrationInterval: @(KSAClamp(KSADoubleValue(raw, @"VibrationInterval", 0.7), 0.2, 5.0)),

        kKeySoundEnabled:      @(soundEnabled),
        kKeySoundDuration:     @(KSAClamp(KSADoubleValue(raw, @"SoundDuration", 10.0), 0.1, 120.0)),
        kKeySoundVolume:       @(KSAClamp(KSADoubleValue(raw, @"SoundVolume", 0.8), 0.0, 1.0)),
        kKeySoundLoop:         @(KSABoolValue(raw, @"SoundLoop", YES)),
        kKeySoundFile:         KSAStringValue(raw, @"SoundFile", nil) ?: @"",
        kKeySoundChannel:      KSAStringValue(raw, @"SoundChannel", nil).lowercaseString ?: @"alert",
        kKeySoundRepeatInterval: @(KSAClamp(KSADoubleValue(raw, @"SoundRepeatInterval", 0.0), 0.0, 10.0)),

        kKeyDuplicateInterval: @(KSAClamp(KSADoubleValue(raw, @"DuplicateInterval", 10.0), 0.0, 3600.0)),
        kKeyOnNewMatchedSMS:   @(policy),

        kKeyDebugEnabled:      @(KSABoolValue(raw, @"DebugEnabled", NO)),
        kKeyLogToFile:         @(KSABoolValue(raw, @"LogToFile", NO)),
        kKeyTestAlertOnLoad:   @(KSABoolValue(raw, @"TestAlertOnLoad", NO)),
        kKeyMessageStoreBackstop:   @(KSABoolValue(raw, @"HookMessageStoreBackstop", YES)),
        kKeyServiceSessionBackstop: @(KSABoolValue(raw, @"HookServiceSessionBackstop", YES)),
    };
}

// --- accessors ----------------------------------------------------------------
- (NSDictionary *)_snapshot
{
    @synchronized (self) {
        return _snapshot;
    }
}

- (BOOL)enabled { return [self._snapshot[kKeyEnabled] boolValue]; }
- (NSArray<NSString *> *)keywords { return self._snapshot[kKeyKeywords]; }
- (KSAMatchMode)matchMode { return (KSAMatchMode)[self._snapshot[kKeyMatchMode] integerValue]; }
- (BOOL)caseInsensitive { return [self._snapshot[kKeyCaseInsensitive] boolValue]; }
- (NSUInteger)minMessageLength { return [self._snapshot[kKeyMinMessageLength] unsignedIntegerValue]; }
- (NSArray<NSString *> *)ignoreSenders { return self._snapshot[kKeyIgnoreSenders]; }
- (BOOL)includeIMessage { return [self._snapshot[kKeyIncludeIMessage] boolValue]; }

- (KSAAlertMode)alertMode { return (KSAAlertMode)[self._snapshot[kKeyAlertMode] integerValue]; }
- (BOOL)vibrationEnabled { return [self._snapshot[kKeyVibrationEnabled] boolValue]; }
- (NSTimeInterval)vibrationDuration { return [self._snapshot[kKeyVibrationDuration] doubleValue]; }
- (NSTimeInterval)vibrationInterval { return [self._snapshot[kKeyVibrationInterval] doubleValue]; }

- (BOOL)soundEnabled { return [self._snapshot[kKeySoundEnabled] boolValue]; }
- (NSTimeInterval)soundDuration { return [self._snapshot[kKeySoundDuration] doubleValue]; }
- (float)soundVolume { return [self._snapshot[kKeySoundVolume] floatValue]; }
- (BOOL)soundLoop { return [self._snapshot[kKeySoundLoop] boolValue]; }
- (NSString *)soundFileConfigurationValue { return self._snapshot[kKeySoundFile]; }
- (NSString *)soundChannel
{
    NSString *channel = self._snapshot[kKeySoundChannel];
    return [channel isEqualToString:@"media"] ? @"media" : @"alert";
}
- (NSTimeInterval)soundRepeatInterval { return [self._snapshot[kKeySoundRepeatInterval] doubleValue]; }

- (NSTimeInterval)duplicateInterval { return [self._snapshot[kKeyDuplicateInterval] doubleValue]; }
- (KSAOnNewMatchedSMS)onNewMatchedSMS { return (KSAOnNewMatchedSMS)[self._snapshot[kKeyOnNewMatchedSMS] integerValue]; }

- (BOOL)debugEnabled { return [self._snapshot[kKeyDebugEnabled] boolValue]; }
- (BOOL)logToFile { return [self._snapshot[kKeyLogToFile] boolValue]; }
- (BOOL)testAlertOnLoad { return [self._snapshot[kKeyTestAlertOnLoad] boolValue]; }
- (BOOL)messageStoreBackstop { return [self._snapshot[kKeyMessageStoreBackstop] boolValue]; }
- (BOOL)serviceSessionBackstop { return [self._snapshot[kKeyServiceSessionBackstop] boolValue]; }

- (NSString *)activeConfigPath
{
    @synchronized (self) {
        return _activePath;
    }
}

// --- matching -----------------------------------------------------------------
- (NSString *)matchedKeywordInText:(NSString *)text
{
    if (!self.enabled || text.length == 0) {
        return nil;
    }
    if (text.length < self.minMessageLength) {
        return nil;
    }

    NSArray<NSString *> *keywords = self.keywords;
    if (keywords.count == 0) {
        return nil;
    }

    NSStringCompareOptions options = 0;
    if (self.caseInsensitive) {
        options |= NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    }

    KSAMatchMode matchMode = self.matchMode;
    for (NSString *keyword in keywords) {
        if (keyword.length == 0) {
            continue;
        }

        NSRange range = NSMakeRange(NSNotFound, 0);
        switch (matchMode) {
            case KSAMatchModeExact:
                if ([text compare:keyword options:options] == NSOrderedSame) {
                    return keyword;
                }
                break;
            case KSAMatchModePrefix:
                range = [text rangeOfString:keyword options:(options | NSAnchoredSearch)];
                break;
            case KSAMatchModeContains:
            default:
                range = [text rangeOfString:keyword options:options];
                break;
        }

        if (range.location != NSNotFound) {
            return keyword;
        }
    }

    return nil;
}

- (BOOL)shouldIgnoreSender:(NSString *)sender
{
    if (sender.length == 0) {
        return NO;
    }

    for (NSString *ignored in self.ignoreSenders) {
        if (ignored.length == 0) {
            continue;
        }
        if ([sender rangeOfString:ignored
                          options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)resolvedSoundPath
{
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    NSString *configured = self.soundFileConfigurationValue;
    if (configured.length > 0) {
        if ([configured hasPrefix:@"/"]) {
            NSString *inJB = KSAPathInJB(configured);
            if (inJB.length > 0) {
                [candidates addObject:inJB];
            }
            [candidates addObject:configured];
        } else {
            NSString *inJB = KSAPathInJB([@"/Library/KeywordSMSAlert/" stringByAppendingString:configured]);
            if (inJB.length > 0) {
                [candidates addObject:inJB];
            }
        }
    }

    // Default jailbreak locations, then a stock iOS sound so that an alert can
    // always be played even if the bundled asset is missing.
    NSString *defaultInJB = KSAPathInJB(@"/Library/KeywordSMSAlert/alert.caf");
    if (defaultInJB.length > 0) {
        [candidates addObject:defaultInJB];
    }
    [candidates addObject:@"/var/mobile/Library/KeywordSMSAlert/alert.caf"];
    [candidates addObject:@"/System/Library/Audio/UISounds/sms-received1.caf"];
    [candidates addObject:@"/System/Library/Audio/UISounds/new-mail.caf"];

    return KSAFirstExistingPath(candidates);
}

- (NSString *)debugDescription
{
    NSMutableArray<NSString *> *keywordHashes = [NSMutableArray array];
    for (NSString *keyword in self.keywords) {
        [keywordHashes addObject:KSAHashString(keyword) ?: @"?"];
    }

    return [NSString stringWithFormat:
            @"enabled=%d keywords=%lu[%@] matchMode=%ld caseInsensitive=%d includeIMessage=%d alertMode=%ld "
            @"vib=%d/%.1fs@%.1fs sound=%d/%.1fs vol=%.2f loop=%d channel=%@ dup=%.1fs policy=%ld debug=%d test=%d",
            self.enabled,
            (unsigned long)self.keywords.count,
            [keywordHashes componentsJoinedByString:@","],
            (long)self.matchMode,
            self.caseInsensitive,
            self.includeIMessage,
            (long)self.alertMode,
            self.vibrationEnabled, self.vibrationDuration, self.vibrationInterval,
            self.soundEnabled, self.soundDuration, self.soundVolume, self.soundLoop,
            self.soundChannel,
            self.duplicateInterval,
            (long)self.onNewMatchedSMS,
            self.debugEnabled,
            self.testAlertOnLoad];
}

@end
