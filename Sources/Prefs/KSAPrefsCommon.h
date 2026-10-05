//
//  KSAPrefsCommon.h
//  KeywordSMSAlert - settings bundle (runs inside the Settings app)
//
//  The settings panel only READS/WRITES the same configuration plist the tweak uses:
//
//      /var/mobile/Library/Preferences/com.keyword.smsalert.plist        (preferred)
//      <jbroot>/var/mobile/Library/Preferences/com.keyword.smsalert.plist (packaged default)
//
//  It deliberately does not link libsubstrate / AVFoundation / libroothide: the
//  jailbreak root is derived from the bundle's own path instead, so the bundle
//  keeps loading even if the Settings app is not injected by the jailbreak.
//

#ifndef KSA_PREFS_COMMON_H
#define KSA_PREFS_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// Localised string from this bundle.
FOUNDATION_EXPORT NSString *KSAPrefsLocalized(NSString *key);

/// Custom PSSpecifier property keys (shared between the controllers).
FOUNDATION_EXPORT NSString *const KSAPropertyKey;
FOUNDATION_EXPORT NSString *const KSAPropertyValues;
FOUNDATION_EXPORT NSString *const KSAPropertyTitles;
FOUNDATION_EXPORT NSString *const KSAPropertyDefault;

#endif /* KSA_PREFS_COMMON_H */
