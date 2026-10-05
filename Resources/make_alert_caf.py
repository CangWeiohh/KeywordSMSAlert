#!/usr/bin/env python3
"""Generate Resources/alert.caf - the bundled KeywordSMSAlert alert tone.

The file is a plain "CAF" (Apple Core Audio Format) container with 16 bit signed
little endian LPCM mono audio at 44100 Hz, which AVAudioPlayer can loop directly.

Usage:  python3 Resources/make_alert_caf.py
Output: Resources/alert.caf  (and a copy is installed by the package layout)
"""

import math
import os
import struct

SAMPLE_RATE = 44100
BEEP_FREQUENCIES = (880.0, 1174.0)   # A5 / D6, clearly audible but not harsh
BEEP_DURATION = 0.18
GAP_DURATION = 0.09
REPEATS = 4
AMPLITUDE = 0.62
FADE = 0.008                          # click free ramps


def _beep(frequency, duration):
    frames = int(SAMPLE_RATE * duration)
    fade_frames = max(1, int(SAMPLE_RATE * FADE))
    samples = []
    for index in range(frames):
        value = math.sin(2.0 * math.pi * frequency * index / SAMPLE_RATE)
        # smooth envelope: fade in at the start, fade out at the end
        if index < fade_frames:
            value *= index / fade_frames
        elif index > frames - fade_frames:
            value *= max(0.0, (frames - index) / fade_frames)
        samples.append(int(max(-1.0, min(1.0, value * AMPLITUDE)) * 32767))
    return samples


def _silence(duration):
    return [0] * int(SAMPLE_RATE * duration)


def build_samples():
    samples = []
    for repeat in range(REPEATS):
        samples.extend(_beep(BEEP_FREQUENCIES[repeat % len(BEEP_FREQUENCIES)], BEEP_DURATION))
        if repeat != REPEATS - 1:
            samples.extend(_silence(GAP_DURATION))
    return samples


def caf_bytes(samples):
    pcm = struct.pack("<%dh" % len(samples), *samples)

    # 'caff' file header: magic, version (uint16), flags (uint16) - all big endian.
    header = b"caff" + struct.pack(">HH", 1, 0)

    # 'desc' chunk: AudioStreamBasicDescription, big endian, 32 bytes.
    asc = struct.pack(
        ">d4sIIIIIII",
        float(SAMPLE_RATE),          # mSampleRate
        b"lpcm",                     # mFormatID
        0x0C,                        # mFormatFlags: signed integer | packed (little endian)
        2,                           # mBytesPerPacket
        1,                           # mFramesPerPacket
        2,                           # mBytesPerFrame
        1,                           # mChannelsPerFrame
        16,                          # mBitsPerChannel
        0,                           # mReserved
    )
    desc_chunk = b"desc" + struct.pack(">q", len(asc)) + asc

    # 'data' chunk: int32 edit count, then the PCM payload.
    data_payload = struct.pack(">i", 0) + pcm
    data_chunk = b"data" + struct.pack(">q", len(data_payload)) + data_payload

    return header + desc_chunk + data_chunk


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    samples = build_samples()
    data = caf_bytes(samples)
    out = os.path.join(here, "alert.caf")
    with open(out, "wb") as handle:
        handle.write(data)

    duration = len(samples) / float(SAMPLE_RATE)
    print("wrote %s (%d bytes, %.2f s, %d Hz, 16 bit mono LPCM)"
          % (out, len(data), duration, SAMPLE_RATE))


if __name__ == "__main__":
    main()
