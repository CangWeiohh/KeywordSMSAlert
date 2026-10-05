//
//  KSASoundConverter.m
//  KeywordSMSAlert
//

#import "KSASoundConverter.h"

#import <AudioToolbox/AudioToolbox.h>

/// Small local hash (FNV-1a 64) used to name the cache file. Kept inside this file so
/// the converter stays dependency free: it is linked into the alert dylib *and* into the
/// Settings bundle, which deliberately does not compile KSACommon.
static NSString *KSASoundConverterCacheName(NSString *string)
{
    const char *bytes = string.UTF8String;
    if (bytes == NULL) {
        return @"sound";
    }
    uint64_t hash = 1469598103934665603ULL;
    for (const unsigned char *cursor = (const unsigned char *)bytes; *cursor != 0; cursor++) {
        hash ^= (uint64_t)(*cursor);
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"alert-%016llx.caf", (unsigned long long)hash];
}

/// The system sound path refuses anything longer than 30 seconds; stay below that.
static const NSTimeInterval KSASoundConvertMaxDuration = 28.0;

BOOL KSASoundFileSupportsAlertChannel(NSString *soundPath)
{
    NSString *extension = soundPath.pathExtension.lowercaseString;
    return [extension isEqualToString:@"caf"] ||
           [extension isEqualToString:@"aif"] ||
           [extension isEqualToString:@"aiff"] ||
           [extension isEqualToString:@"wav"] ||
           [extension isEqualToString:@"wave"];
}

NSString *KSAPCMCopyOfSoundFileInDirectory(NSString *sourcePath, NSString *cacheDirectory)
{
    if (sourcePath.length == 0) {
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:sourcePath]) {
        return nil;
    }

    // --- open the source -----------------------------------------------------
    ExtAudioFileRef input = NULL;
    CFURLRef sourceURL = (__bridge CFURLRef)[NSURL fileURLWithPath:sourcePath];
    if (ExtAudioFileOpenURL(sourceURL, &input) != noErr || input == NULL) {
        return nil;
    }

    AudioStreamBasicDescription sourceFormat = {0};
    UInt32 formatSize = sizeof(sourceFormat);
    if (ExtAudioFileGetProperty(input, kExtAudioFileProperty_FileDataFormat, &formatSize, &sourceFormat) != noErr) {
        ExtAudioFileDispose(input);
        return nil;
    }

    if (sourceFormat.mFormatID == kAudioFormatLinearPCM &&
        sourceFormat.mBitsPerChannel == 16 &&
        sourceFormat.mChannelsPerFrame >= 1) {
        ExtAudioFileDispose(input);
        return sourcePath;   // already usable by the system sound path
    }

    // --- destination: 16 bit signed packed LPCM, mono ------------------------
    if (cacheDirectory.length == 0) {
        ExtAudioFileDispose(input);
        return nil;
    }
    if (![fileManager fileExistsAtPath:cacheDirectory]) {
        [fileManager createDirectoryAtPath:cacheDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    }

    NSDictionary<NSString *, id> *attributes = [fileManager attributesOfItemAtPath:sourcePath error:NULL];
    unsigned long long modified = [attributes[NSFileModificationDate] timeIntervalSince1970];
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%llu", sourcePath, modified];
    NSString *target = [cacheDirectory stringByAppendingPathComponent:KSASoundConverterCacheName(cacheKey)];
    if ([fileManager fileExistsAtPath:target]) {
        ExtAudioFileDispose(input);
        return target;   // cached conversion for this exact source revision
    }

    AudioStreamBasicDescription targetFormat = {0};
    targetFormat.mSampleRate = sourceFormat.mSampleRate > 8000 ? sourceFormat.mSampleRate : 44100.0;
    targetFormat.mFormatID = kAudioFormatLinearPCM;
    targetFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    targetFormat.mChannelsPerFrame = 1;
    targetFormat.mBitsPerChannel = 16;
    targetFormat.mBytesPerFrame = 2;
    targetFormat.mFramesPerPacket = 1;
    targetFormat.mBytesPerPacket = 2;

    ExtAudioFileRef output = NULL;
    CFURLRef targetURL = (__bridge CFURLRef)[NSURL fileURLWithPath:target];
    OSStatus status = ExtAudioFileCreateWithURL(targetURL, kAudioFileCAFType, &targetFormat,
                                                NULL, kAudioFileFlags_EraseFile, &output);
    if (status != noErr || output == NULL) {
        ExtAudioFileDispose(input);
        return nil;
    }

    if (ExtAudioFileSetProperty(output, kExtAudioFileProperty_ClientDataFormat, sizeof(targetFormat), &targetFormat) != noErr ||
        ExtAudioFileSetProperty(input, kExtAudioFileProperty_ClientDataFormat, sizeof(targetFormat), &targetFormat) != noErr) {
        ExtAudioFileDispose(input);
        ExtAudioFileDispose(output);
        [fileManager removeItemAtPath:target error:NULL];
        return nil;
    }

    const UInt32 framesPerRead = 8192;
    const UInt64 frameBudget = (UInt64)(targetFormat.mSampleRate * KSASoundConvertMaxDuration);
    UInt8 *scratch = (UInt8 *)calloc(framesPerRead, targetFormat.mBytesPerFrame);
    AudioBufferList *bufferList = (AudioBufferList *)malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer));

    BOOL succeeded = (scratch != NULL && bufferList != NULL);
    if (succeeded) {
        bufferList->mNumberBuffers = 1;
        bufferList->mBuffers[0].mNumberChannels = 1;
        bufferList->mBuffers[0].mData = scratch;
    }

    UInt64 written = 0;
    while (succeeded && written < frameBudget) {
        UInt32 frameCount = framesPerRead;
        bufferList->mBuffers[0].mDataByteSize = framesPerRead * targetFormat.mBytesPerFrame;
        OSStatus readStatus = ExtAudioFileRead(input, &frameCount, bufferList);
        if (readStatus != noErr || frameCount == 0) {
            break;
        }
        if (ExtAudioFileWrite(output, frameCount, bufferList) != noErr) {
            succeeded = NO;
            break;
        }
        written += frameCount;
    }

    if (bufferList != NULL) {
        free(bufferList);
    }
    if (scratch != NULL) {
        free(scratch);
    }
    ExtAudioFileDispose(input);
    ExtAudioFileDispose(output);

    if (!succeeded || written == 0 || ![fileManager fileExistsAtPath:target]) {
        [fileManager removeItemAtPath:target error:NULL];
        return nil;
    }

    return target;
}
