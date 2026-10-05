#!/usr/bin/env python3
"""Generate the Settings icon for the KeywordSMSAlert preference bundle.

Pure stdlib PNG writer (RGBA8), 4x4 supersampled. Draws a blue rounded square with
a white bell - recognisable at 29pt in the Settings list.

Usage: python3 Resources/make_icon.py
Output: PrefsResources/icon.png, icon@2x.png, icon@3x.png
"""

import os
import struct
import zlib

BLUE_TOP = (10, 132, 255)
BLUE_BOTTOM = (0, 90, 200)
WHITE = (255, 255, 255)


def _png_bytes(width, height, pixels):
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0
        for x in range(width):
            raw.extend(pixels[y * width + x])

    def chunk(tag, payload):
        data = tag + payload
        return struct.pack(">I", len(payload)) + data + struct.pack(">I", zlib.crc32(data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def _rounded_rect_contains(x, y, size, radius):
    cx = min(max(x, radius), size - radius)
    cy = min(max(y, radius), size - radius)
    dx = x - cx
    dy = y - cy
    return dx * dx + dy * dy <= radius * radius


def _bell_contains(x, y, s):
    """Bell silhouette, all coordinates in 0..1."""
    # top handle
    if 0.455 <= x <= 0.545 and 0.175 <= y <= 0.26:
        return True
    # dome
    if y <= 0.46 and (x - 0.5) ** 2 + (y - 0.44) ** 2 <= 0.235 ** 2:
        return True
    # body, widening downwards
    if 0.46 < y <= 0.67:
        t = (y - 0.46) / 0.21
        half = 0.235 + t * 0.10
        if abs(x - 0.5) <= half:
            return True
    # flared base
    if 0.67 < y <= 0.715:
        if ((x - 0.5) / 0.345) ** 2 + ((y - 0.685) / 0.032) ** 2 <= 1.0:
            return True
    # clapper
    if (x - 0.5) ** 2 + (y - 0.785) ** 2 <= 0.078 ** 2:
        return True
    return False


def render(size):
    samples = 4
    radius = size * 0.235
    pixels = []
    for py in range(size):
        for px in range(size):
            acc_r = acc_g = acc_b = acc_a = 0
            for sy in range(samples):
                for sx in range(samples):
                    x = (px + (sx + 0.5) / samples) / size
                    y = (py + (sy + 0.5) / samples) / size
                    if not _rounded_rect_contains(x * size, y * size, size, radius):
                        continue
                    if _bell_contains(x, y, size):
                        colour = WHITE
                    else:
                        t = y
                        colour = tuple(int(BLUE_TOP[i] + (BLUE_BOTTOM[i] - BLUE_TOP[i]) * t) for i in range(3))
                    acc_r += colour[0]
                    acc_g += colour[1]
                    acc_b += colour[2]
                    acc_a += 255
            total = samples * samples
            if acc_a == 0:
                pixels.append((0, 0, 0, 0))
            else:
                covered = acc_a / 255.0
                pixels.append((int(acc_r / covered), int(acc_g / covered), int(acc_b / covered), int(acc_a / total)))
    return _png_bytes(size, size, pixels)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(os.path.dirname(here), "PrefsResources")
    os.makedirs(out_dir, exist_ok=True)
    for name, size in (("icon.png", 29), ("icon@2x.png", 58), ("icon@3x.png", 87)):
        path = os.path.join(out_dir, name)
        with open(path, "wb") as handle:
            handle.write(render(size))
        print("wrote %s (%dx%d)" % (path, size, size))


if __name__ == "__main__":
    main()
