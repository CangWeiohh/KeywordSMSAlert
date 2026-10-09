//
//  KSARuntimeStatus.h
//  Small file-backed diagnostics for users without SSH/Terminal.
//

#ifndef KSA_RUNTIME_STATUS_H
#define KSA_RUNTIME_STATUS_H

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *KSARuntimeStatusPath(void);
FOUNDATION_EXPORT void KSARuntimeStatusReset(void);
FOUNDATION_EXPORT void KSARuntimeStatusUpdate(NSDictionary<NSString *, id> *values);

#endif
