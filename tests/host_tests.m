//
//  tests/host_tests.m
//  KeywordSMSAlert - host (macOS) unit tests for the platform independent logic.
//
//  These tests compile the real KSAConfig / KSADedupCache sources and exercise:
//    * configuration parsing (XML plist, keyword list, defaults)
//    * keyword matching (Chinese, ASCII case insensitivity, exact/prefix/contains)
//    * alert mode derivation and value clamping
//    * sender ignore list
//    * sound file resolution
//    * de-duplication TTL window (DuplicateInterval)
//  They do not and cannot test hooks, vibration or audio playback.
//
//  Build & run: tests/run_host_tests.sh
//

#import <Foundation/Foundation.h>
#import "KSAConfig.h"
#import "KSACommon.h"
#import "KSADedupCache.h"
#import "Daemon/KSAHIDEventMatcher.h"

static NSUInteger sPassed = 0;
static NSUInteger sFailed = 0;

#define KSA_CHECK(condition, ...) do { \
    if (condition) { \
        sPassed++; \
        printf("  ok   %s\n", [[NSString stringWithFormat:__VA_ARGS__] UTF8String]); \
    } else { \
        sFailed++; \
        printf("  FAIL %s\n", [[NSString stringWithFormat:__VA_ARGS__] UTF8String]); \
    } \
} while (0)

static NSString *KSATempDirectory(void)
{
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"ksa-tests-%d", getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return directory;
}

static NSString *KSAWriteConfig(NSString *directory, NSString *name, NSDictionary *configuration)
{
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:configuration
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:NULL];
    [data writeToFile:path atomically:YES];
    return path;
}

static void KSATestDefaults(NSString *directory)
{
    printf("\n[1] built-in defaults (no configuration file)\n");
    KSAConfig *config = [KSAConfig sharedInstance];
    [config forceReloadFromPath:[directory stringByAppendingPathComponent:@"does-not-exist.plist"]];

    KSA_CHECK(config.enabled, @"Enabled defaults to YES");
    KSA_CHECK([config.keywords containsObject:@"验证码"], @"default keyword 验证码 present");
    KSA_CHECK(config.alertMode == KSAAlertModeBoth, @"AlertMode defaults to 3 (vibrate+sound)");
    KSA_CHECK(config.vibrationEnabled && config.soundEnabled, @"both channels enabled by default");
    KSA_CHECK(fabs(config.duplicateInterval - 10.0) < 0.001, @"DuplicateInterval defaults to 10s");
    KSA_CHECK(config.matchMode == KSAMatchModeContains, @"MatchMode defaults to contains");
}

static void KSATestParsing(NSString *directory)
{
    printf("\n[2] XML plist parsing and alert mode derivation\n");
    NSDictionary *raw = @{
        @"Enabled": @YES,
        @"Keywords": @[ @"验证码", @"Payment" ],
        @"MatchMode": @"exact",
        @"CaseInsensitive": @NO,
        @"AlertMode": @1,
        @"VibrationDuration": @7,
        @"VibrationInterval": @0.01,
        @"SoundEnabled": @YES,
        @"SoundDuration": @3,
        @"SoundVolume": @1.5,
        @"DuplicateInterval": @30,
        @"OnNewMatchedSMS": @"queue",
        @"IgnoreSenders": @[ @"1069" ],
        @"IncludeIMessage": @YES,
    };
    NSString *path = KSAWriteConfig(directory, @"full.plist", raw);

    KSAConfig *config = [KSAConfig sharedInstance];
    [config forceReloadFromPath:path];

    KSA_CHECK([config.keywords isEqualToArray:raw[@"Keywords"]], @"keywords parsed, %lu entries",
              (unsigned long)config.keywords.count);
    KSA_CHECK(config.matchMode == KSAMatchModeExact, @"MatchMode string \"exact\" parsed");
    KSA_CHECK(!config.caseInsensitive, @"CaseInsensitive = NO honoured");
    KSA_CHECK(config.alertMode == KSAAlertModeVibrate, @"AlertMode 1 parsed");
    KSA_CHECK(config.vibrationEnabled && !config.soundEnabled,
              @"AlertMode 1 disables the sound channel even though SoundEnabled=1");
    KSA_CHECK(fabs(config.vibrationDuration - 7.0) < 0.001, @"VibrationDuration = 7");
    KSA_CHECK(fabs(config.vibrationInterval - 0.2) < 0.001,
              @"VibrationInterval 0.01 clamped up to the 0.2s safety floor");
    KSA_CHECK(fabs(config.soundVolume - 1.0) < 0.001, @"SoundVolume 1.5 clamped to 1.0");
    KSA_CHECK(fabs(config.duplicateInterval - 30.0) < 0.001, @"DuplicateInterval = 30");
    KSA_CHECK(config.onNewMatchedSMS == KSAOnNewMatchedSMSQueue, @"OnNewMatchedSMS=queue parsed");
    KSA_CHECK([config shouldIgnoreSender:@"+8610691234"], @"IgnoreSenders substring match works");
    KSA_CHECK(![config shouldIgnoreSender:@"10086"], @"unrelated sender is not ignored");
    KSA_CHECK(config.includeIMessage, @"IncludeIMessage parsed");
}

static void KSATestMatching(NSString *directory)
{
    printf("\n[3] keyword matching\n");
    KSAConfig *config = [KSAConfig sharedInstance];
    [config forceReloadFromPath:KSAWriteConfig(directory, @"match.plist", @{
        @"Keywords": @[ @"验证码", @"Payment" ],
        @"MatchMode": @"contains",
        @"CaseInsensitive": @YES,
    })];

    KSA_CHECK([config matchedKeywordInText:@"【某平台】您的验证码为 123456"] != nil,
              @"Chinese contains match on a real OTP SMS body");
    KSA_CHECK([config matchedKeywordInText:@"please PAYMENT received"] != nil,
              @"ASCII match is case insensitive");
    KSA_CHECK([config matchedKeywordInText:@"今晚一起吃饭"] == nil,
              @"unrelated Chinese SMS does not match");
    KSA_CHECK([config matchedKeywordInText:@""] == nil, @"empty body does not match");

    // exact
    [config forceReloadFromPath:KSAWriteConfig(directory, @"exact.plist", @{
        @"Keywords": @[ @"验证码" ],
        @"MatchMode": @"exact",
    })];
    KSA_CHECK([config matchedKeywordInText:@"验证码"] != nil, @"exact mode matches the whole body");
    KSA_CHECK([config matchedKeywordInText:@"【x】验证码 123456"] == nil,
              @"exact mode rejects a body that merely contains the keyword");

    // prefix
    [config forceReloadFromPath:KSAWriteConfig(directory, @"prefix.plist", @{
        @"Keywords": @[ @"您的验证码" ],
        @"MatchMode": @"prefix",
    })];
    KSA_CHECK([config matchedKeywordInText:@"您的验证码是 123456"] != nil, @"prefix mode matches the start");
    KSA_CHECK([config matchedKeywordInText:@"xx 您的验证码 123456"] == nil, @"prefix mode is anchored");

    // empty keyword list -> never match
    [config forceReloadFromPath:KSAWriteConfig(directory, @"empty.plist", @{
        @"Keywords": @[],
    })];
    KSA_CHECK(config.keywords.count == 0, @"an explicitly empty Keywords list stays empty");
    KSA_CHECK([config matchedKeywordInText:@"验证码 123456"] == nil,
              @"empty keyword list never triggers (requirement: 关键词为空时不触发)");
    KSA_CHECK([config matchedKeywordInText:@"任何内容"] == nil,
              @"empty keyword list never triggers for any body");
}

static void KSATestDedup(void)
{
    printf("\n[4] de-duplication window\n");
    KSADedupCache *cache = [[KSADedupCache alloc] init];

    KSA_CHECK(![cache isDuplicateKey:@"guid-1" window:10.0], @"first occurrence is not a duplicate");
    KSA_CHECK([cache isDuplicateKey:@"guid-1" window:10.0], @"immediate repeat is suppressed");
    KSA_CHECK(![cache isDuplicateKey:@"guid-2" window:10.0], @"a different GUID is not suppressed");
    KSA_CHECK(![cache isDuplicateKey:@"" window:10.0], @"an empty key is never suppressed");
    KSA_CHECK([cache isDuplicateKey:nil window:10.0] == NO, @"a nil key is never suppressed");
    usleep(20 * 1000);  // let the 10 ms window elapse
    KSA_CHECK(![cache isDuplicateKey:@"guid-1" window:0.01], @"entry older than the window is accepted again");

    [cache reset];
    KSA_CHECK(![cache isDuplicateKey:@"guid-1" window:10.0], @"reset() clears the memory");
}

static void KSATestSoundResolution(NSString *directory)
{
    printf("\n[5] alert sound resolution\n");
    KSAConfig *config = [KSAConfig sharedInstance];

    NSString *sound = [directory stringByAppendingPathComponent:@"custom.caf"];
    [[NSData data] writeToFile:sound atomically:YES];
    [config forceReloadFromPath:KSAWriteConfig(directory, @"sound.plist", @{ @"SoundFile": sound })];
    KSA_CHECK([config.resolvedSoundPath isEqualToString:sound],
              @"configured SoundFile is resolved");

    [config forceReloadFromPath:KSAWriteConfig(directory, @"nosound.plist", @{})];
    KSA_CHECK(config.resolvedSoundPath == nil || [config.resolvedSoundPath hasSuffix:@".caf"],
              @"with no configuration the resolver falls back to a .caf path or nil (host: %@)",
              config.resolvedSoundPath ?: @"nil");
}

static void KSATestHIDMatcher(void)
{
    printf("\n[6] standalone HID power-button matcher\n");
    KSA_CHECK(KSAHIDEventIsPowerButtonDown(3, 0x0C, 0x30, 1),
              @"Consumer/Power DOWN is accepted");
    KSA_CHECK(!KSAHIDEventIsPowerButtonDown(3, 0x0C, 0x30, 0),
              @"Consumer/Power UP is ignored");
    KSA_CHECK(!KSAHIDEventIsPowerButtonDown(3, 0x0C, 0xE9, 1),
              @"volume-up is not mistaken for power");
    KSA_CHECK(!KSAHIDEventIsPowerButtonDown(3, 0x0C, 0xEA, 1),
              @"volume-down is not mistaken for power");
    KSA_CHECK(!KSAHIDEventIsPowerButtonDown(11, 0x0C, 0x30, 1),
              @"non-keyboard HID events are ignored");
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        printf("KeywordSMSAlert host tests (logic only: no hooks, no audio)\n");
        NSString *directory = KSATempDirectory();

        KSATestDefaults(directory);
        KSATestParsing(directory);
        KSATestMatching(directory);
        KSATestDedup();
        KSATestSoundResolution(directory);
        KSATestHIDMatcher();

        [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];

        printf("\n%d passed, %d failed\n", (int)sPassed, (int)sFailed);
        return sFailed == 0 ? 0 : 1;
    }
}
