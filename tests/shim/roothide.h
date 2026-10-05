//
//  tests/shim/roothide.h
//  Host (macOS) test shim for the roothide API used by KSACommon.m.
//
//  On the device, jbroot() comes from libroothide.dylib and maps a jbroot based
//  path onto the randomised jailbreak root. The host tests do not have a jailbreak,
//  so the identity mapping is used. This keeps the *logic* under test
//  (configuration parsing, keyword matching, de-duplication) unchanged.
//

#ifndef ROOTHIDE_SHIM_H
#define ROOTHIDE_SHIM_H

#import <Foundation/Foundation.h>

static inline NSString *__attribute__((overloadable)) jbroot(NSString *path) { return path; }
static inline const char *jbroot(const char *path) { return path; }

#endif /* ROOTHIDE_SHIM_H */
