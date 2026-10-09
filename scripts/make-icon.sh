#!/bin/zsh
# Regenerates Resources/AppIcon.icns from scripts/MakeIcon.swift.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/AppIcon.iconset Resources
swiftc -O -module-cache-path build/module-cache scripts/MakeIcon.swift -o build/MakeIcon
build/MakeIcon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
printf 'Wrote %s/Resources/AppIcon.icns\n' "$PWD"
