//
//  KeywordSMSAlertSpringBoardProbe.m
//  Diagnostic C: intentionally inert SpringBoard injection probe.
//
//  This file must stay API-call-free and side-effect-free.  Theos' tweak target may
//  retain its baseline Foundation/CoreFoundation load commands, but this probe does
//  not import or call either framework and does not link AVFoundation/AudioToolbox.
//  It performs no ObjC messaging, allocates nothing, installs no hooks, creates no
//  queues, registers no observers and never touches display/audio state.  Its only
//  purpose is to let the device answer one question: does the mere presence of an
//  additional SpringBoard dylib reproduce the CallAssist coexistence black screen?
//

static volatile unsigned char sKSAProbeLoaded = 0;

__attribute__((constructor))
static void KSAProbeConstructor(void)
{
    sKSAProbeLoaded = 1;
}
