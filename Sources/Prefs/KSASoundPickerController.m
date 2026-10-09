//
//  KSASoundPickerController.m
//  KeywordSMSAlert
//
//  Lists the sounds that ship with iOS (system alert / SMS tones) and the installed
//  ringtones. Tapping a row does two things at once:
//
//      * selects it (writes SoundFile + saves, so it is live immediately), and
//      * plays a preview of it.
//
//  Tapping the same row again stops the preview, leaving the screen stops it too.
//  The preview uses the same channel as the alert itself (ringer/alert volume by
//  default), so what you hear here is what the reminder will sound like.
//

#import "KSASoundPickerController.h"
#import "KSAPrefsCommon.h"
#import "KSAPrefsStore.h"
#import "KSASoundConverter.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

static const NSUInteger KSASoundPickerMaxEntries = 400;
static const NSUInteger KSASoundPickerMaxDepth = 4;

@implementation KSASoundPickerController
{
    SystemSoundID _previewSoundID;
    AVAudioPlayer *_previewPlayer;
    NSString *_previewPath;
    NSString *_previewPlayablePath;
}

#pragma mark - Sound discovery

- (NSArray<NSString *> *)ksaSearchDirectories
{
    return @[
        @"/System/Library/Audio/UISounds",
        @"/Library/Ringtones",
        @"/System/Library/Audio/UISounds/Ringtones",
        @"/var/mobile/Media/Ringtones",
        @"/var/mobile/Media/iTunes_Control/Ringtones",
    ];
}

- (BOOL)ksaIsSupportedSound:(NSString *)path
{
    static NSSet<NSString *> *extensions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[ @"caf", @"aif", @"aiff", @"wav", @"wave",
                                            @"m4r", @"mp3", @"m4a", @"aac" ]];
    });
    return [extensions containsObject:path.pathExtension.lowercaseString];
}

- (NSArray<NSString *> *)ksaCollectSounds
{
    NSMutableArray<NSString *> *sounds = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    for (NSString *directory in [self ksaSearchDirectories]) {
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
            continue;
        }

        NSURL *baseURL = [NSURL fileURLWithPath:directory];
        NSDirectoryEnumerator<NSURL *> *enumerator =
            [fileManager enumeratorAtURL:baseURL
              includingPropertiesForKeys:@[ NSURLIsDirectoryKey ]
                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                            errorHandler:nil];
        for (NSURL *url in enumerator) {
            NSNumber *isDirectoryValue = nil;
            [url getResourceValue:&isDirectoryValue forKey:NSURLIsDirectoryKey error:NULL];
            if (isDirectoryValue.boolValue) {
                NSString *relative = [url.path substringFromIndex:directory.length];
                if ([[relative componentsSeparatedByString:@"/"] count] > KSASoundPickerMaxDepth) {
                    [enumerator skipDescendents];
                }
                continue;
            }
            if ([self ksaIsSupportedSound:url.path]) {
                [sounds addObject:url.path];
                if (sounds.count >= KSASoundPickerMaxEntries) {
                    return [sounds sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
                }
            }
        }
    }
    return [sounds sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

#pragma mark - Selection / preview

- (NSString *)ksaConfigurationKey
{
    return [self.specifier propertyForKey:KSAPropertyKey] ?: @"SoundFile";
}

- (NSString *)ksaCurrentValue
{
    return [[KSAPrefsStore sharedStore] stringForKey:[self ksaConfigurationKey] defaultValue:@""];
}

/// Stops whatever the preview is currently playing. Best effort for the system sound
/// path (iOS gives no hard stop for system sounds, but disposing the id stops it in
/// practice and every preview is short anyway).
- (void)ksaStopPreview
{
    BOOL wasPlaying = (_previewPath.length > 0);

    if (_previewSoundID != 0) {
        AudioServicesDisposeSystemSoundID(_previewSoundID);
        _previewSoundID = 0;
    }
    if (_previewPlayer != nil) {
        [_previewPlayer stop];
        _previewPlayer = nil;
    }
    if (_previewPlayablePath.length > 0 && ![_previewPlayablePath isEqualToString:_previewPath]) {
        // Preview transcode inside the Settings container: safe to drop.
        [[NSFileManager defaultManager] removeItemAtPath:_previewPlayablePath error:NULL];
    }
    _previewPath = nil;
    _previewPlayablePath = nil;

    if (wasPlaying) {
        [self reloadSpecifiers];
    }
}

- (void)ksaPlayPreviewAtPath:(NSString *)path
{
    [self ksaStopPreview];

    KSAPrefsStore *store = [KSAPrefsStore sharedStore];
    BOOL useAlertChannel = ![[store stringForKey:@"SoundChannel" defaultValue:@"alert"] isEqualToString:@"media"];

    if (useAlertChannel) {
        NSString *playable = path;
        if (!KSASoundFileSupportsAlertChannel(path)) {
            // Ringtone / mp3 / compressed CAF: convert into the Settings sandbox first.
            playable = KSAPCMCopyOfSoundFileInDirectory(path, NSTemporaryDirectory());
        }
        if (playable.length > 0) {
            SystemSoundID soundID = 0;
            OSStatus status = AudioServicesCreateSystemSoundID((__bridge CFURLRef)[NSURL fileURLWithPath:playable],
                                                               &soundID);
            if (status == kAudioServicesNoError && soundID != 0) {
                _previewSoundID = soundID;
                _previewPath = path;
                _previewPlayablePath = [playable isEqualToString:path] ? nil : playable;
                AudioServicesPlaySystemSound(_previewSoundID);
                [self reloadSpecifiers];
                return;
            }
            if (![playable isEqualToString:path]) {
                [[NSFileManager defaultManager] removeItemAtPath:playable error:NULL];
            }
        }
    }

    // Media channel (or the alert channel refused the file): AVAudioPlayer preview.
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:NULL];
    [session setActive:YES error:NULL];

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&error];
    if (player == nil) {
        return;
    }
    player.volume = (float)[store doubleForKey:@"SoundVolume" defaultValue:0.8];
    [player play];
    _previewPlayer = player;
    _previewPath = path;
    [self reloadSpecifiers];
}

#pragma mark - Playable copy

/// Directory the alert engine (imagent) can definitely read: it is where its own
/// configuration lives, and it is on the real rootfs rather than in the jailbreak root.
static NSString *KSASoundPickerPlayableDirectory(void)
{
    return @"/var/mobile/Library/KeywordSMSAlert";
}

/// Returns a path the alert engine can play, or nil when the sound cannot be used.
/// CAF/AIFF/WAV are returned as-is; everything else (m4r ringtones, mp3, ...) is
/// transcoded to 16 bit PCM CAF under a stable name.
- (NSString *)ksaPreparePlayableCopyOfSoundAtPath:(NSString *)path
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *directory = KSASoundPickerPlayableDirectory();
    [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];

    if (KSASoundFileSupportsAlertChannel(path)) {
        return path;
    }

    NSString *converted = KSAPCMCopyOfSoundFileInDirectory(path, directory);
    if (converted.length == 0) {
        return nil;
    }
    if ([converted isEqualToString:path]) {
        return converted;
    }

    NSString *target = [directory stringByAppendingPathComponent:@"custom-alert.caf"];
    [fileManager removeItemAtPath:target error:NULL];
    NSError *error = nil;
    if (![fileManager moveItemAtPath:converted toPath:target error:&error]) {
        return converted;
    }
    return target;
}

#pragma mark - Specifiers

- (NSArray *)specifiers
{
    NSArray *existing = [super specifiers];
    if (existing.count > 0) {
        return existing;
    }

    NSMutableArray *specifiers = [NSMutableArray array];
    NSString *current = [self ksaCurrentValue];

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
    NSMutableString *footer = [NSMutableString stringWithFormat:KSAPrefsLocalized(@"FooterSoundPicker"),
                               current.length > 0 ? current : KSAPrefsLocalized(@"SoundBuiltIn")];

    // Tell the user which file the reminder will really use, and say so explicitly when
    // a chosen sound could not be converted (this used to fail silently).
    NSString *playable = [[KSAPrefsStore sharedStore] stringForKey:@"SoundFilePlayable" defaultValue:@""];
    NSFileManager *footerFileManager = [NSFileManager defaultManager];
    if (playable.length > 0 && [footerFileManager fileExistsAtPath:playable]) {
        NSDictionary *attributes = [footerFileManager attributesOfItemAtPath:playable error:NULL];
        double kilobytes = [attributes[NSFileSize] unsignedLongLongValue] / 1024.0;
        [footer appendFormat:@"\n%@", [NSString stringWithFormat:KSAPrefsLocalized(@"FooterSoundPickerConverted"),
                                       playable.lastPathComponent,
                                       [NSString stringWithFormat:@"%.0f KB", kilobytes]]];
    } else if (current.length > 0 && !KSASoundFileSupportsAlertChannel(current)) {
        [footer appendFormat:@"\n%@", KSAPrefsLocalized(@"FooterSoundPickerConvertFailed")];
    }

    [group setProperty:footer forKey:@"footerText"];
    [specifiers addObject:group];

    NSArray<NSString *> *sounds = [self ksaCollectSounds];
    if (sounds.count == 0) {
        PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:KSAPrefsLocalized(@"SoundNoneFound")
                                                            target:self set:nil get:nil
                                                            detail:nil cell:PSTitleValueCell edit:nil];
        [specifiers addObject:empty];
        [self setSpecifiers:specifiers];
        return specifiers;
    }

    NSUInteger index = 0;
    for (NSString *path in sounds) {
        NSString *displayName = path.lastPathComponent.stringByDeletingPathExtension;
        NSString *marker = @"";
        if ([path isEqualToString:_previewPath]) {
            marker = @"▶ ";
        } else if ([path isEqualToString:current]) {
            marker = @"✓ ";
        }

        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:[marker stringByAppendingString:displayName]
                                                         target:self set:nil get:nil
                                                         detail:nil cell:PSTitleValueCell edit:nil];
        row.identifier = [NSString stringWithFormat:@"ksa-sound-%lu", (unsigned long)index];
        [row setProperty:path forKey:@"ksaSoundPath"];
        [specifiers addObject:row];
        index++;
    }

    [self setSpecifiers:specifiers];
    return specifiers;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = KSAPrefsLocalized(@"SoundPicker");
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (void)viewWillDisappear:(BOOL)animated
{
    // Leaving this screen (back button) always stops the preview.
    [self ksaStopPreview];
    [super viewWillDisappear:animated];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    PSSpecifier *row = [self specifierAtIndexPath:indexPath];
    NSString *path = [row propertyForKey:@"ksaSoundPath"];
    if (path.length == 0) {
        return;
    }

    // Tapping the sound that is currently previewing stops it.
    if ([path isEqualToString:_previewPath]) {
        [self ksaStopPreview];
        return;
    }

    KSAPrefsStore *store = [KSAPrefsStore sharedStore];

    // SoundFile keeps the ORIGINAL choice, so the ✓ in this list keeps matching the row
    // the user tapped. The playable file goes into SoundFilePlayable: the alert engine
    // runs inside imagent, whose sandbox cannot be assumed to read /Library/Ringtones
    // or the jailbreak root, so the conversion is done HERE, in the Settings process.
    [store setString:path forKey:[self ksaConfigurationKey]];
    NSString *playable = [self ksaPreparePlayableCopyOfSoundAtPath:path];
    [store setString:playable ?: @"" forKey:@"SoundFilePlayable"];
    [store save];
    if ([self.parentController isKindOfClass:[PSListController class]]) {
        [(PSListController *)self.parentController reloadSpecifiers];
    }

    // Stay on the list so other sounds can be compared; the ✓ follows the selection.
    [self ksaPlayPreviewAtPath:path];
}

@end
