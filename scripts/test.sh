#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p build
swiftc -parse-as-library -sdk "$SDK" -module-cache-path build/module-cache Sources/FrameForge/Model.swift Sources/FrameForge/CaptureGeometry.swift Sources/FrameForge/SmartEdits.swift Sources/FrameForge/AudioPCM.swift scripts/SmartCheck.swift scripts/ModelCheck.swift -o build/ModelCheck
build/ModelCheck
if [[ "${1:-}" != "--integration" && "${1:-}" != "--composition" ]]; then
  exit 0
fi
swiftc -parse-as-library -sdk "$SDK" -target "$(uname -m)-apple-macosx13.0" -module-cache-path build/module-cache Sources/FrameForge/Model.swift Sources/FrameForge/MediaEngine.swift Sources/FrameForge/SmartEdits.swift Sources/FrameForge/AudioPCM.swift scripts/EngineCheck.swift -o build/EngineCheck
if [[ "${1:-}" == "--composition" ]]; then
  if ! command -v ffmpeg >/dev/null; then
    printf 'Composition fixture generation requires ffmpeg. No package is installed automatically.\n'
    exit 1
  fi
  mkdir -p build/test-media
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=30:duration=2' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' -itsoffset 0.25 -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=1.75' -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p -c:a pcm_s16le -metadata:s:a:0 title='System Audio' -metadata:s:a:1 title='Microphone' build/test-media/fixture.mov
  build/EngineCheck build/test-media --existing-fixture --compose-only
else
  build/EngineCheck build/test-media
fi
