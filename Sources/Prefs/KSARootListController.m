//
//  KSARootListController.m
//  KeywordSMSAlert
//
//  Root pane. Every row writes straight into the configuration plist that the tweak
//  reads (/var/mobile/Library/Preferences/com.keyword.smsalert.plist) and posts the
//  Darwin reload notification so the standalone alert daemon and imagent apply it.
//

#import "KSARootListController.h"
#import "KSAChoiceController.h"
#import "KSAListEditorController.h"
#import "KSASoundPickerController.h"
#import "KSAPrefsCommon.h"
#import "KSAPrefsStore.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

static NSString *const KSAReloadNotificationName = @"com.keyword.smsalert.reload";
static NSString *const KSATriggerNotificationName = @"com.keyword.smsalert.trigger";

@implementation KSARootListController

#pragma mark - Specifier helpers

- (PSSpecifier *)ksaSwitchRow:(NSString *)label key:(NSString *)key defaultValue:(BOOL)defaultValue
{
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:label
                                                      target:self
                                                         set:@selector(ksaWriteBool:specifier:)
                                                         get:@selector(ksaReadBool:)
                                                      detail:nil
                                                        cell:PSSwitchCell
                                                        edit:nil];
    row.identifier = key;
    [row setProperty:key forKey:KSAPropertyKey];
    [row setProperty:@(defaultValue) forKey:KSAPropertyDefault];
    return row;
}

- (PSSpecifier *)ksaTextRow:(NSString *)label key:(NSString *)key defaultValue:(id)defaultValue
{
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:label
                                                      target:self
                                                         set:@selector(ksaWriteText:specifier:)
                                                         get:@selector(ksaReadText:)
                                                      detail:nil
                                                        cell:PSEditTextCell
                                                        edit:nil];
    row.identifier = key;
    [row setProperty:key forKey:KSAPropertyKey];
    [row setProperty:defaultValue forKey:KSAPropertyDefault];
    return row;
}

/// `identifier` is the row identity, `valueKey` is the configuration key the pushed
/// controller works on. They are usually the same, but e.g. the sound picker row writes
/// SoundFile - passing the row identity as the value key was a real bug.
- (PSSpecifier *)ksaLinkRow:(NSString *)label
                 identifier:(NSString *)identifier
                   valueKey:(NSString *)valueKey
                 controller:(Class)controllerClass
{
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:label
                                                      target:self
                                                         set:nil
                                                         get:nil
                                                      detail:controllerClass
                                                        cell:PSLinkCell
                                                        edit:nil];
    row.identifier = identifier;
    [row setProperty:valueKey forKey:KSAPropertyKey];
    return row;
}

- (PSSpecifier *)ksaChoiceRow:(NSString *)label
                          key:(NSString *)key
                       values:(NSArray<NSString *> *)values
                       titles:(NSArray<NSString *> *)titles
                     fallback:(NSString *)fallback
{
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:label
                                                      target:self
                                                         set:nil
                                                         get:@selector(ksaReadChoiceTitle:)
                                                      detail:[KSAChoiceController class]
                                                        cell:PSLinkListCell
                                                        edit:nil];
    row.identifier = key;
    [row setProperty:key forKey:KSAPropertyKey];
    [row setProperty:values forKey:KSAPropertyValues];
    [row setProperty:titles forKey:KSAPropertyTitles];
    [row setProperty:fallback forKey:KSAPropertyDefault];
    return row;
}

- (PSSpecifier *)ksaButtonRow:(NSString *)label action:(SEL)action
{
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:label
                                                      target:self
                                                         set:nil
                                                         get:nil
                                                      detail:nil
                                                        cell:PSButtonCell
                                                        edit:nil];
    row.buttonAction = action;
    [row setProperty:NSStringFromSelector(action) forKey:@"action"];
    [row setProperty:@YES forKey:@"enabled"];
    return row;
}

- (PSSpecifier *)ksaValueRow:(NSString *)label getter:(SEL)getter
{
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:label
                                                      target:self
                                                         set:nil
                                                         get:getter
                                                      detail:nil
                                                        cell:PSTitleValueCell
                                                        edit:nil];
    return row;
}

- (PSSpecifier *)ksaGroup:(NSString *)title footer:(NSString *)footer
{
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:title];
    if (footer.length > 0) {
        [group setProperty:footer forKey:@"footerText"];
    }
    return group;
}

#pragma mark - Specifiers

- (NSArray *)specifiers
{
    NSArray *existing = [super specifiers];
    if (existing.count > 0) {
        return existing;
    }

    NSMutableArray *specifiers = [NSMutableArray array];
    KSAPrefsStore *store = [KSAPrefsStore sharedStore];

    // --- 总开关 -------------------------------------------------------------
    [specifiers addObject:[self ksaGroup:nil footer:KSAPrefsLocalized(@"FooterGeneral")]];
    [specifiers addObject:[self ksaSwitchRow:KSAPrefsLocalized(@"Enabled") key:@"Enabled" defaultValue:YES]];

    // --- 关键词 -------------------------------------------------------------
    [specifiers addObject:[self ksaGroup:KSAPrefsLocalized(@"GroupKeywords")
                                  footer:KSAPrefsLocalized(@"FooterKeywords")]];
    [specifiers addObject:[self ksaLinkRow:KSAPrefsLocalized(@"Keywords")
                                identifier:@"Keywords"
                                  valueKey:@"Keywords"
                                controller:[KSAListEditorController class]]];
    [specifiers addObject:[self ksaChoiceRow:KSAPrefsLocalized(@"MatchMode")
                                         key:@"MatchMode"
                                      values:@[ @"contains", @"exact", @"prefix" ]
                                      titles:@[ KSAPrefsLocalized(@"MatchContains"),
                                                KSAPrefsLocalized(@"MatchExact"),
                                                KSAPrefsLocalized(@"MatchPrefix") ]
                                    fallback:@"contains"]];
    [specifiers addObject:[self ksaSwitchRow:KSAPrefsLocalized(@"CaseInsensitive")
                                         key:@"CaseInsensitive"
                                defaultValue:YES]];
    [specifiers addObject:[self ksaLinkRow:KSAPrefsLocalized(@"IgnoreSenders")
                                identifier:@"IgnoreSenders"
                                  valueKey:@"IgnoreSenders"
                                controller:[KSAListEditorController class]]];

    // --- 提醒方式 -----------------------------------------------------------
    [specifiers addObject:[self ksaGroup:KSAPrefsLocalized(@"GroupAlert")
                                  footer:KSAPrefsLocalized(@"FooterAlert")]];
    [specifiers addObject:[self ksaChoiceRow:KSAPrefsLocalized(@"AlertMode")
                                         key:@"AlertMode"
                                      values:@[ @"0", @"1", @"2", @"3" ]
                                      titles:@[ KSAPrefsLocalized(@"AlertOff"),
                                                KSAPrefsLocalized(@"AlertVibrate"),
                                                KSAPrefsLocalized(@"AlertSound"),
                                                KSAPrefsLocalized(@"AlertBoth") ]
                                    fallback:@"3"]];
    [specifiers addObject:[self ksaSwitchRow:KSAPrefsLocalized(@"VibrationEnabled")
                                         key:@"VibrationEnabled"
                                defaultValue:YES]];
    [specifiers addObject:[self ksaTextRow:KSAPrefsLocalized(@"VibrationDuration")
                                       key:@"VibrationDuration"
                              defaultValue:@5]];
    [specifiers addObject:[self ksaTextRow:KSAPrefsLocalized(@"VibrationInterval")
                                       key:@"VibrationInterval"
                              defaultValue:@0.7]];
    [specifiers addObject:[self ksaSwitchRow:KSAPrefsLocalized(@"SoundEnabled")
                                         key:@"SoundEnabled"
                                defaultValue:YES]];
    [specifiers addObject:[self ksaTextRow:KSAPrefsLocalized(@"SoundDuration")
                                       key:@"SoundDuration"
                              defaultValue:@10]];
    [specifiers addObject:[self ksaTextRow:KSAPrefsLocalized(@"SoundVolume")
                                       key:@"SoundVolume"
                              defaultValue:@0.8]];
    [specifiers addObject:[self ksaChoiceRow:KSAPrefsLocalized(@"SoundChannel")
                                         key:@"SoundChannel"
                                      values:@[ @"alert", @"media" ]
                                      titles:@[ KSAPrefsLocalized(@"ChannelAlert"),
                                                KSAPrefsLocalized(@"ChannelMedia") ]
                                    fallback:@"alert"]];
    [specifiers addObject:[self ksaSwitchRow:KSAPrefsLocalized(@"SoundLoop")
                                         key:@"SoundLoop"
                                defaultValue:YES]];
    [specifiers addObject:[self ksaLinkRow:KSAPrefsLocalized(@"SoundPicker")
                                identifier:@"SoundPicker"
                                  valueKey:@"SoundFile"
                                controller:[KSASoundPickerController class]]];
    [specifiers addObject:[self ksaTextRow:KSAPrefsLocalized(@"SoundFile")
                                       key:@"SoundFile"
                              defaultValue:@""]];

    // --- 行为 ---------------------------------------------------------------
    [specifiers addObject:[self ksaGroup:KSAPrefsLocalized(@"GroupBehaviour")
                                  footer:KSAPrefsLocalized(@"FooterBehaviour")]];
    [specifiers addObject:[self ksaTextRow:KSAPrefsLocalized(@"DuplicateInterval")
                                       key:@"DuplicateInterval"
                              defaultValue:@10]];
    [specifiers addObject:[self ksaTextRow:KSAPrefsLocalized(@"PollInterval")
                                       key:@"PollInterval"
                              defaultValue:@1]];
    [specifiers addObject:[self ksaChoiceRow:KSAPrefsLocalized(@"OnNewMatchedSMS")
                                         key:@"OnNewMatchedSMS"
                                      values:@[ @"restart", @"ignore", @"queue" ]
                                      titles:@[ KSAPrefsLocalized(@"PolicyRestart"),
                                                KSAPrefsLocalized(@"PolicyIgnore"),
                                                KSAPrefsLocalized(@"PolicyQueue") ]
                                    fallback:@"restart"]];
    [specifiers addObject:[self ksaSwitchRow:KSAPrefsLocalized(@"IncludeIMessage")
                                         key:@"IncludeIMessage"
                                defaultValue:NO]];

    // --- 调试与测试 ---------------------------------------------------------
    [specifiers addObject:[self ksaGroup:KSAPrefsLocalized(@"GroupDebug")
                                  footer:[NSString stringWithFormat:KSAPrefsLocalized(@"FooterDebug"),
                                          [store activePathDescription]]]];
    [specifiers addObject:[self ksaSwitchRow:KSAPrefsLocalized(@"DebugEnabled")
                                         key:@"DebugEnabled"
                                defaultValue:NO]];
    [specifiers addObject:[self ksaSwitchRow:KSAPrefsLocalized(@"LogToFile")
                                         key:@"LogToFile"
                                defaultValue:NO]];
    [specifiers addObject:[self ksaValueRow:KSAPrefsLocalized(@"RuntimeStatus")
                                      getter:@selector(ksaRuntimeStatus:)]];
    [specifiers addObject:[self ksaSwitchRow:KSAPrefsLocalized(@"TestAlertOnLoad")
                                         key:@"TestAlertOnLoad"
                                defaultValue:NO]];
    [specifiers addObject:[self ksaButtonRow:KSAPrefsLocalized(@"TestAlertNow")
                                      action:@selector(ksaTestAlertTapped:)]];

    [self setSpecifiers:specifiers];
    return specifiers;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // Values may have been changed by a child pane.
    [self reloadSpecifiers];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = KSAPrefsLocalized(@"PrefsTitle");
}

#pragma mark - Getters / setters used by the cells

- (id)ksaReadBool:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:KSAPropertyKey];
    BOOL fallback = [[specifier propertyForKey:KSAPropertyDefault] boolValue];
    return @([[KSAPrefsStore sharedStore] boolForKey:key defaultValue:fallback]);
}

- (void)ksaWriteBool:(id)value specifier:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:KSAPropertyKey];
    if (key.length == 0) {
        return;
    }
    [[KSAPrefsStore sharedStore] setBool:[value boolValue] forKey:key];
    [[KSAPrefsStore sharedStore] save];
}

- (id)ksaReadText:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:KSAPropertyKey];
    id fallback = [specifier propertyForKey:KSAPropertyDefault];
    NSString *defaultString = [fallback isKindOfClass:[NSNumber class]] ? [fallback stringValue] : (fallback ?: @"");
    return [[KSAPrefsStore sharedStore] stringForKey:key defaultValue:defaultString];
}

/// Shows the localised title of the currently selected option in the row itself.
- (id)ksaReadChoiceTitle:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:KSAPropertyKey];
    NSArray *values = [specifier propertyForKey:KSAPropertyValues] ?: @[];
    NSArray *titles = [specifier propertyForKey:KSAPropertyTitles] ?: @[];
    NSString *fallback = [specifier propertyForKey:KSAPropertyDefault] ?: values.firstObject;
    NSString *current = [[KSAPrefsStore sharedStore] stringForKey:key defaultValue:fallback];
    NSUInteger index = [values indexOfObject:current];
    return (index != NSNotFound && index < titles.count) ? titles[index] : (current ?: @"");
}

- (id)ksaRuntimeStatus:(PSSpecifier *)specifier
{
    NSString *path = @"/var/mobile/Library/Preferences/com.keyword.smsalert.runtime.plist";
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:path];
    BOOL running = [status[@"DaemonRunning"] boolValue] || [status[@"AlertEngineReady"] boolValue];
    if (!running) {
        return KSAPrefsLocalized(@"RuntimeNotRunning");
    }
    NSString *sound = [status[@"LastSoundFile"] lastPathComponent];
    NSString *suffix = sound.length > 0
        ? [NSString stringWithFormat:@" · %@%@", KSAPrefsLocalized(@"RuntimeSoundPrefix"), sound]
        : @"";

    // Which stop source is live? The precise HID power-button observer is preferred;
    // the lock-state source is the fallback (see KSADisplayStateStop).
    if ([status[@"HIDDelivering"] boolValue]) {
        // Events are flowing. Show the raw counters and the last keyboard event, so the
        // HID usage this device's power button really reports is readable here.
        NSMutableString *row = [NSMutableString stringWithString:KSAPrefsLocalized(@"RuntimeStopHID")];
        [row appendFormat:KSAPrefsLocalized(@"RuntimeHIDCounters"),
         status[@"HIDEventsSeen"] ?: @0,
         status[@"HIDKeyboardEvents"] ?: @0];
        if (status[@"HIDLastUsage"] != nil) {
            [row appendFormat:KSAPrefsLocalized(@"RuntimeHIDLast"),
             [NSString stringWithFormat:@"%llX", [status[@"HIDLastPage"] unsignedLongLongValue]],
             [NSString stringWithFormat:@"%llX", [status[@"HIDLastUsage"] unsignedLongLongValue]],
             [status[@"HIDLastDown"] boolValue] ? @"↓" : @"↑"];
        }
        if (status[@"HIDPowerHits"] != nil) {
            [row appendFormat:@" · %@", status[@"HIDPowerHits"]];
        }
        return [row stringByAppendingString:suffix];
    }
    if ([status[@"HIDAvailable"] boolValue]) {
        // The client exists but nothing has ever arrived: imagent is not allowed to
        // receive HID events, so the lock/unlock source is what actually stops alerts.
        return [KSAPrefsLocalized(@"RuntimeStopHIDNoEvents") stringByAppendingString:suffix];
    }
    if ([status[@"LockStopActive"] boolValue]) {
        NSString *base = [KSAPrefsLocalized(@"RuntimeStopLock") stringByAppendingString:suffix];
        if (status[@"HIDStatus"] != nil) {
            base = [NSString stringWithFormat:@"%@（%@）", base, status[@"HIDStatus"]];
        }
        return base;
    }
    return [KSAPrefsLocalized(@"RuntimeReady") stringByAppendingString:suffix];
}

- (void)ksaWriteText:(id)value specifier:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:KSAPropertyKey];
    if (key.length == 0) {
        return;
    }
    NSString *string = [value isKindOfClass:[NSString class]] ? value : [value stringValue];
    string = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [[KSAPrefsStore sharedStore] setString:string forKey:key];
    if ([key isEqualToString:@"SoundFile"]) {
        // Typed by hand: the converted copy the picker produced no longer applies.
        [[KSAPrefsStore sharedStore] setString:@"" forKey:@"SoundFilePlayable"];
    }
    [[KSAPrefsStore sharedStore] save];
}

#pragma mark - Test button

- (void)ksaTestAlertTapped:(PSSpecifier *)specifier
{
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    if (center == NULL) {
        return;
    }
    CFNotificationCenterPostNotification(center,
                                         (__bridge CFNotificationName)KSATriggerNotificationName,
                                         NULL, NULL, true);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:KSAPrefsLocalized(@"TestAlertSentTitle")
                                                                  message:KSAPrefsLocalized(@"TestAlertSentMessage")
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:KSAPrefsLocalized(@"OK")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
