#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
ICONSET="$PWD/build/FrameForge.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
# ICNS stores PNG representations under size-specific four-character types.
# Pack directly so builds also work where iconutil's image service is unavailable.
python3 - <<'ICONPY'
from pathlib import Path
import struct
representations = [
    ("icp4", "16x16"), ("icp5", "32x32"), ("icp6", "32x32@2x"),
    ("ic07", "128x128"), ("ic08", "256x256"), ("ic09", "512x512"),
    ("ic10", "512x512@2x"), ("ic11", "16x16@2x"),
    ("ic12", "32x32@2x"), ("ic13", "128x128@2x"), ("ic14", "256x256@2x"),
]
chunks = []
for kind, size in representations:
    data = Path(f"build/FrameForge.iconset/icon_{size}.png").read_bytes()
    chunks.append(kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
payload = b"".join(chunks)
Path("build/FrameForge.icns").write_bytes(b"icns" + struct.pack(">I",len(payload)+8) + payload)
ICONPY
