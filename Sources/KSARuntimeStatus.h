//
//  KSARuntimeStatus.h
//  Small file-backed diagnostics for users without SSH/Terminal.
//

#ifndef KSA_RUNTIME_STATUS_H
#define KSA_RUNTIME_STATUS_H

#import <Foundation/Foundation.h>

/// Absolute path of the status file, as a literal.
///
/// The Settings bundle must be able to READ the status without linking this
/// implementation (it runs in the Preferences process and should stay tiny), so the
/// path lives here as a macro and KSARuntimeStatusPath() simply returns it. Never
/// hard-code the string anywhere else.
#define KSA_RUNTIME_STATUS_PATH @"/var/mobile/Library/Preferences/com.keyword.smsalert.runtime.plist"

FOUNDATION_EXPORT NSString *KSARuntimeStatusPath(void);
FOUNDATION_EXPORT void KSARuntimeStatusReset(void);
FOUNDATION_EXPORT void KSARuntimeStatusUpdate(NSDictionary<NSString *, id> *values);

#endif
