#!/usr/bin/env python3
"""Generate small opaque RGB placeholder art for local GameKit definitions (3840×2160, 72 ppi)."""
from pathlib import Path
import struct
import zlib


def make_image():
    width, height = 3840, 2160
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            color = (8, 32, 29)
            if x % 240 < 3 or y % 240 < 3:
                color = (15, 55, 48)
            for center, tint in ((1400, (55, 220, 160)), (2440, (60, 190, 235))):
                if abs(x - center) < 300 and abs(y - 1080) < 300:
                    color = tint
                    if 970 < y < 1060 and (center - 170 < x < center - 80 or center + 80 < x < center + 170):
                        color = (8, 32, 29)
            rows.extend(color)
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'pHYs', struct.pack('>IIB', 2835, 2835, 1)) + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b''))


if __name__ == '__main__':
    path = Path(__file__).resolve().parents[1] / 'App/DemoBotsLocal.gamekit/repair.png'
    path.write_bytes(make_image())
