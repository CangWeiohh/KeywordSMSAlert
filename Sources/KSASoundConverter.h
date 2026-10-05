//
//  KSASoundConverter.h
//  KeywordSMSAlert
//
//  Converts any pickable sound (m4r ringtones, mp3, compressed CAF, ...) into an
//  16 bit PCM CAF that the CoreAudio "system sound" path accepts, so the alert can be
//  played through the RINGER/alert volume channel instead of the media volume.
//

#ifndef KSA_SOUND_CONVERTER_H
#define KSA_SOUND_CONVERTER_H

#import <Foundation/Foundation.h>

/// YES when the extension is one the CoreAudio system sound path accepts directly
/// (uncompressed CAF/AIFF/WAV). Other formats need conversion - see below.
FOUNDATION_EXPORT BOOL KSASoundFileSupportsAlertChannel(NSString *soundPath);

/// Returns a playable 16 bit LPCM CAF path for `soundPath`:
///   * `soundPath` itself when it already is 16 bit LPCM,
///   * a cached conversion inside `cacheDirectory` otherwise (the file is named from
///     the source path + modification date, so a changed sound re-converts),
///   * nil when the file cannot be read/converted.
/// The caller chooses the cache directory: the tweak uses the jailbreak directory,
/// the Settings bundle uses its own temporary directory (it deliberately does not link
/// the roothide API).
FOUNDATION_EXPORT NSString *KSAPCMCopyOfSoundFileInDirectory(NSString *soundPath,
                                                            NSString *cacheDirectory);

#endif /* KSA_SOUND_CONVERTER_H */
