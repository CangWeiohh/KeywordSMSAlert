//
//  KSAChoiceController.m
//  KeywordSMSAlert
//

#import "KSAChoiceController.h"
#import "KSAPrefsCommon.h"
#import "KSAPrefsStore.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

@implementation KSAChoiceController

- (NSString *)ksaKey
{
    return [self.specifier propertyForKey:KSAPropertyKey];
}

- (NSArray<NSString *> *)ksaValues
{
    return [self.specifier propertyForKey:KSAPropertyValues] ?: @[];
}

- (NSArray<NSString *> *)ksaTitles
{
    return [self.specifier propertyForKey:KSAPropertyTitles] ?: @[];
}

- (NSString *)ksaCurrentValue
{
    NSString *fallback = [self.specifier propertyForKey:KSAPropertyDefault] ?: self.ksaValues.firstObject;
    return [[KSAPrefsStore sharedStore] stringForKey:[self ksaKey] defaultValue:fallback];
}

- (NSArray *)specifiers
{
    NSArray *existing = [super specifiers];
    if (existing.count > 0) {
        return existing;
    }

    NSMutableArray *specifiers = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
    [group setProperty:KSAPrefsLocalized(@"FooterChooseOne") forKey:@"footerText"];
    [specifiers addObject:group];

    NSArray<NSString *> *values = [self ksaValues];
    NSArray<NSString *> *titles = [self ksaTitles];
    NSString *current = [self ksaCurrentValue];

    for (NSUInteger index = 0; index < values.count; index++) {
        NSString *value = values[index];
        NSString *title = index < titles.count ? titles[index] : value;
        BOOL selected = [value isEqualToString:current];

        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:(selected ? [@"✓ " stringByAppendingString:title] : title)
                                                         target:self
                                                            set:nil
                                                            get:nil
                                                         detail:nil
                                                           cell:PSTitleValueCell
                                                           edit:nil];
        row.identifier = [NSString stringWithFormat:@"ksa-choice-%lu", (unsigned long)index];
        [row setProperty:value forKey:@"ksaValue"];
        [specifiers addObject:row];
    }

    [self setSpecifiers:specifiers];
    return specifiers;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = KSAPrefsLocalized([self ksaKey]);
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    PSSpecifier *row = [self specifierAtIndexPath:indexPath];
    NSString *value = [row propertyForKey:@"ksaValue"];
    if (value.length == 0) {
        return;
    }

    KSAPrefsStore *store = [KSAPrefsStore sharedStore];
    [store setString:value forKey:[self ksaKey]];
    [store save];

    if ([self.parentController isKindOfClass:[PSListController class]]) {
        [(PSListController *)self.parentController reloadSpecifiers];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end
