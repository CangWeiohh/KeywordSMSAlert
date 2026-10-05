//
//  KSAListEditorController.m
//  KeywordSMSAlert
//
//  Pushed from the root pane for "Keywords" and "IgnoreSenders". Entries can be
//  added (＋), edited (tap) and deleted (tap -> delete). Everything is written back
//  through KSAPrefsStore.
//

#import "KSAListEditorController.h"
#import "KSAPrefsCommon.h"
#import "KSAPrefsStore.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

@implementation KSAListEditorController

- (NSString *)ksaKey
{
    NSString *key = [self.specifier propertyForKey:KSAPropertyKey];
    return key.length > 0 ? key : @"Keywords";
}

- (NSArray<NSString *> *)ksaItems
{
    return [[KSAPrefsStore sharedStore] arrayForKey:[self ksaKey]];
}

- (void)ksaCommitItems:(NSArray<NSString *> *)items
{
    [[KSAPrefsStore sharedStore] setArray:items forKey:[self ksaKey]];
    [[KSAPrefsStore sharedStore] save];
    [self reloadSpecifiers];
}

- (NSArray *)specifiers
{
    NSArray *existing = [super specifiers];
    if (existing.count > 0) {
        return existing;
    }

    NSMutableArray *specifiers = [NSMutableArray array];
    NSArray<NSString *> *items = [self ksaItems];

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:KSAPrefsLocalized(@"GroupItems")];
    [group setProperty:(items.count == 0 ? KSAPrefsLocalized(@"EmptyListHint")
                                         : KSAPrefsLocalized(@"FooterTouchToEdit"))
                forKey:@"footerText"];
    [specifiers addObject:group];

    NSUInteger index = 0;
    for (NSString *item in items) {
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:item
                                                         target:self
                                                            set:nil
                                                            get:nil
                                                         detail:nil
                                                           cell:PSTitleValueCell
                                                           edit:nil];
        row.identifier = [NSString stringWithFormat:@"ksa-item-%lu", (unsigned long)index];
        [row setProperty:item forKey:@"ksaItem"];
        [specifiers addObject:row];
        index++;
    }

    [specifiers addObject:[PSSpecifier groupSpecifierWithName:nil]];
    PSSpecifier *addRow = [PSSpecifier preferenceSpecifierNamed:KSAPrefsLocalized(@"AddItem")
                                                        target:self
                                                           set:nil
                                                           get:nil
                                                        detail:nil
                                                          cell:PSButtonCell
                                                          edit:nil];
    addRow.buttonAction = @selector(ksaAddTapped:);
    [addRow setProperty:NSStringFromSelector(@selector(ksaAddTapped:)) forKey:@"action"];
    [specifiers addObject:addRow];

    [self setSpecifiers:specifiers];
    return specifiers;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = KSAPrefsLocalized([self ksaKey]);
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(ksaAddTapped:)];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

#pragma mark - Actions

- (void)ksaAddTapped:(id)sender
{
    [self ksaPresentEditorForItem:nil atIndex:NSNotFound];
}

- (void)ksaPresentEditorForItem:(NSString *)item atIndex:(NSUInteger)index
{
    NSString *title = (item == nil) ? KSAPrefsLocalized(@"AddItemTitle")
                                    : KSAPrefsLocalized(@"EditItemTitle");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = item;
        textField.placeholder = KSAPrefsLocalized(@"ItemPlaceholder");
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:KSAPrefsLocalized(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:KSAPrefsLocalized(@"Save")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *value = [alert.textFields.firstObject.text
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSMutableArray<NSString *> *items = [[self ksaItems] mutableCopy];
        if (item == nil) {
            if (value.length > 0) {
                [items addObject:value];
            }
        } else if (value.length == 0) {
            if (index < items.count) {
                [items removeObjectAtIndex:index];
            }
        } else if (index < items.count) {
            items[index] = value;
        }
        [self ksaCommitItems:items];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *item = [specifier propertyForKey:@"ksaItem"];
    NSArray<NSString *> *items = [self ksaItems];
    NSUInteger index = [items indexOfObject:item];
    if (item == nil || index == NSNotFound) {
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:KSAPrefsLocalized(@"EditItem")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self ksaPresentEditorForItem:item atIndex:index];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:KSAPrefsLocalized(@"RemoveItem")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        NSMutableArray<NSString *> *mutableItems = [items mutableCopy];
        if (index < mutableItems.count) {
            [mutableItems removeObjectAtIndex:index];
        }
        [self ksaCommitItems:mutableItems];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:KSAPrefsLocalized(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // iPad / popover safety.
    sheet.popoverPresentationController.sourceView = tableView;
    sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
