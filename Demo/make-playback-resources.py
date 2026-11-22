"""Regenerate the procedural Runner.atlas and two-second playback-demo.wav."""
from pathlib import Path
import math
import struct
import wave
import zlib

root = Path(__file__).parent / 'SpriteUIDemo'
atlas = root / 'Runner.atlas'
atlas.mkdir(exist_ok=True)

def chunk(name, data):
    return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data))

for frame in range(8):
    pixels = bytearray(32 * 32 * 4)
    def rect(x, y, w, h, color):
        for py in range(y, y + h):
            for px in range(x, x + w):
                pixels[(py * 32 + px) * 4:(py * 32 + px) * 4 + 4] = bytes(color)
    bob = 1 if frame % 4 in (1, 2) else 0
    rect(8, 6 + bob, 16, 17, (20, 200, 220, 255))
    rect(10, 9 + bob, 12, 7, (245, 250, 255, 255))
    rect(13, 11 + bob, 2, 3, (12, 30, 50, 255))
    rect(19, 11 + bob, 2, 3, (12, 30, 50, 255))
    rect(6, 18 + bob, 20, 3, (255, 150, 35, 255))
    rect(8 + frame % 4, 24, 6, 4, (230, 240, 255, 255))
    rect(18 - frame % 4, 24, 6, 4, (230, 240, 255, 255))
    rows = b''.join(b'\0' + pixels[y * 128:(y + 1) * 128] for y in range(32))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 32, 32, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
    (atlas / f'run-{frame:02}.png').write_bytes(png)

rate = 22050
with wave.open(str(root / 'playback-demo.wav'), 'wb') as sound:
    sound.setnchannels(1)
    sound.setsampwidth(2)
    sound.setframerate(rate)
    samples = []
    notes = [261.63, 329.63, 392, 523.25, 392, 329.63, 293.66, 392]
    for i in range(rate * 2):
        t = i / rate
        local = (t % 0.25) / 0.25
        envelope = min(1, local * 20) * max(0, 1 - local) ** 2
        value = 0.2 * envelope * math.sin(2 * math.pi * notes[min(7, int(t * 4))] * t)
        samples.append(struct.pack('<h', int(32767 * value)))
    sound.writeframes(b''.join(samples))
