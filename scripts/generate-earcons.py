#!/usr/bin/env python3
"""Generates the Google Transcribe earcon family (original works, repo license).

Musical spec (docs/design/experience.md §2): G-major family, soft mallet/marimba
timbre (sine fundamental + gentle harmonics, rounded attack, exponential decay),
< 400ms, quiet (~ -20 dBFS peak). Sounds are frame-synced to motion by the app.
"""
import math
import struct
import wave
from pathlib import Path

SR = 48_000
PEAK = 0.11  # ~ -19 dBFS

def note(freq, dur, attack=0.008, decay=None, amp=1.0, detune_cents=0.0):
    """One mallet-ish note: sine + soft harmonics, rounded attack, exp decay."""
    freq = freq * (2 ** (detune_cents / 1200))
    n = int(SR * dur)
    out = []
    decay = decay if decay is not None else dur
    for i in range(n):
        t = i / SR
        env = min(1.0, t / attack) * math.exp(-3.2 * t / decay)
        s = (math.sin(2 * math.pi * freq * t)
             + 0.28 * math.sin(2 * math.pi * freq * 2 * t)
             + 0.10 * math.sin(2 * math.pi * freq * 3 * t))
        out.append(s * env * amp)
    return out

def mix(*layers):
    n = max(len(l) for l in layers)
    out = [0.0] * n
    for layer in layers:
        for i, v in enumerate(layer):
            out[i] += v
    return out

def delay(samples, seconds):
    return [0.0] * int(SR * seconds) + samples

def write(name, samples):
    peak = max(abs(v) for v in samples) or 1.0
    scale = PEAK / peak
    data = b"".join(struct.pack("<h", int(max(-1, min(1, v * scale)) * 32767)) for v in samples)
    path = OUT / f"{name}.wav"
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(data)
    print(f"{name}.wav  {len(samples)/SR*1000:.0f}ms")

D4, FS4, G4, B4, D5, G5 = 293.66, 369.99, 392.00, 493.88, 587.33, 783.99

OUT = Path(__file__).resolve().parent.parent / "App/Resources/Sounds"
OUT.mkdir(parents=True, exist_ok=True)

# start: D5 grace note rising to G5 — the "listening" swell (Super G lineage: land on G)
write("start", mix(
    note(D5, 0.10, amp=0.55),
    delay(note(G5, 0.24, decay=0.22), 0.055),
))

# stop: the mirror — G5 resolving down to D5 (release → processing)
write("stop", mix(
    note(G5, 0.09, amp=0.5),
    delay(note(D5, 0.20, decay=0.18), 0.05),
))

# lock: ascending G-major arpeggio — "settling in" to hands-free
write("lock", mix(
    note(G4, 0.16, amp=0.8),
    delay(note(B4, 0.16, amp=0.85), 0.06),
    delay(note(D5, 0.22), 0.12),
))

# success: bright G5 tap over a soft G4 octave undertone (text inserted)
write("success", mix(
    note(G4, 0.20, amp=0.35),
    note(G5, 0.18, decay=0.16),
))

# cancel: single muted D4, felt-piano damp, 20 cents flat
write("cancel", note(D4, 0.12, attack=0.004, decay=0.09, detune_cents=-20))

# error: F#4+G4 semitone dyad, muted and dull — never harsh
write("error", mix(
    note(FS4, 0.15, attack=0.006, decay=0.12, amp=0.8),
    note(G4, 0.15, attack=0.006, decay=0.12, amp=0.8),
))

# celebration: onboarding-only G-major flourish
write("celebration", mix(
    note(G4, 0.5, amp=0.7),
    delay(note(B4, 0.5, amp=0.75), 0.09),
    delay(note(D5, 0.5, amp=0.8), 0.18),
    delay(note(G5, 0.7, decay=0.6), 0.27),
))
