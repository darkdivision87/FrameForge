#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
DESTINATION=${1:-"$PWD/build/FrameForge-$VERSION.dmg"}
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/frameforge-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/contents" "${DESTINATION:h}"
ditto build/FrameForge.app "$STAGING/contents/FrameForge.app"
ln -s /Applications "$STAGING/contents/Applications"
codesign --verify --deep --strict "$STAGING/contents/FrameForge.app"
# A hybrid HFS source avoids mounting a temporary disk device while packaging.
hdiutil makehybrid -hfs -hfs-volume-name "FrameForge $VERSION" -o "$STAGING/source.dmg" "$STAGING/contents"
hdiutil convert "$STAGING/source.dmg" -format UDZO -ov -o "$DESTINATION"
hdiutil verify "$DESTINATION"
