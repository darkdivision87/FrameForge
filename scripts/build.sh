#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
SDK=$(xcrun --sdk macosx --show-sdk-path)
ARCH=$(uname -m)
mkdir -p build/FrameForge.app/Contents/MacOS
swiftc -O -parse-as-library -target "${ARCH}-apple-macosx13.0" -sdk "$SDK" -module-cache-path build/module-cache Sources/FrameForge/*.swift -o build/FrameForge.app/Contents/MacOS/FrameForge
cp Info.plist build/FrameForge.app/Contents/Info.plist
codesign --force --sign - build/FrameForge.app
printf 'Built %s/build/FrameForge.app\n' "$PWD"
