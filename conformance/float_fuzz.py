#!/usr/bin/env python3
"""Float fuzz oracle: emit doubles + their leaf-number encodings (Python
semantics, per docs/CHECKPOINT-V2.md) as TSV for float_fuzz.exs to match.

  python3 conformance/float_fuzz.py > /tmp/floats.tsv
  mix run conformance/float_fuzz.exs /tmp/floats.tsv
"""
import random
import struct
import sys

vals = [1e-5, 2.5e-7, -0.0, 0.0, 1.5, -1.5, 45.0, 1e-100, 0.0001, 1e16,
        7.248182946264746e20, 9007199254740992.0, 2.25, 0.1, 1 / 3,
        123456789.123456789, 5e-324, 1.7976931348623157e308]
rng = random.Random(0xF10A7)
for _ in range(4000):
    bits = rng.getrandbits(64)
    (f,) = struct.unpack("<d", struct.pack("<Q", bits))
    if f != f or f in (float("inf"), float("-inf")):
        continue
    vals.append(f)
for _ in range(2000):
    vals.append(rng.uniform(-1e18, 1e18))
    vals.append(rng.uniform(-1, 1))
    vals.append(float(rng.randint(-10**20, 10**20)))


def leaf(f):
    if f == 0:
        return "0"
    if f == int(f) and abs(f) < 1e21:
        return str(int(f))
    return repr(f)


for f in vals:
    # repr round-trips exactly; the Elixir side parses the same literal.
    print(f"{f!r}\t{leaf(f)}")
sys.stderr.write(f"{len(vals)} values\n")
