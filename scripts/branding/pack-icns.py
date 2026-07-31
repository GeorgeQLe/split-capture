#!/usr/bin/env python3
"""Build a deterministic PNG-backed ICNS file.

This is a fallback for macOS releases where iconutil no longer accepts a
classic .iconset directory. Modern macOS accepts PNG payloads for these ICNS
chunk types.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path


CHUNKS = (
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {Path(sys.argv[0]).name} ICONSET OUTPUT", file=sys.stderr)
        return 2

    iconset = Path(sys.argv[1])
    output = Path(sys.argv[2])
    chunks: list[bytes] = []

    for chunk_type, filename in CHUNKS:
        payload = (iconset / filename).read_bytes()
        chunks.append(chunk_type.encode("ascii") + struct.pack(">I", len(payload) + 8) + payload)

    body = b"".join(chunks)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
