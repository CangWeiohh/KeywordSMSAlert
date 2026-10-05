//
//  KSAPrefsStore.h
//  KeywordSMSAlert - configuration store used by the settings panel.
//

#ifndef KSA_PREFS_STORE_H
#define KSA_PREFS_STORE_H

#import <Foundation/Foundation.h>

@interface KSAPrefsStore : NSObject

+ (instancetype)sharedStore;

/// Reloads the configuration from disk (called automatically on first access and
/// after every save).
- (void)reload;

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
- (void)setBool:(BOOL)value forKey:(NSString *)key;

- (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue;
- (void)setDouble:(double)value forKey:(NSString *)key;

- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)defaultValue;
- (void)setString:(NSString *)value forKey:(NSString *)key;

- (NSArray<NSString *> *)arrayForKey:(NSString *)key;
- (void)setArray:(NSArray<NSString *> *)value forKey:(NSString *)key;

/// Persists the current values and asks every KeywordSMSAlert process to reload.
/// Returns YES when at least one file could be written.
- (BOOL)save;

/// Human readable description of where the configuration is stored (footer text).
- (NSString *)activePathDescription;

@end

#endif /* KSA_PREFS_STORE_H */
