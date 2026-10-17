#!/bin/sh
# Builds a universal (Apple silicon + Intel) Release "Narrative Clip Sync.app" and zips it into dist/.
set -eu
cd "$(dirname "$0")/.."

xcodebuild -project ClipSyncApp/NarrativeClipSync.xcodeproj -scheme NarrativeClipSync -configuration Release \
    -derivedDataPath ClipSyncApp/build -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build

app="ClipSyncApp/build/Build/Products/Release/Narrative Clip Sync.app"
mkdir -p dist
rm -f dist/NarrativeClipSync.zip
ditto -c -k --keepParent "$app" dist/NarrativeClipSync.zip
lipo -archs "$app/Contents/MacOS/Narrative Clip Sync"
echo "dist/NarrativeClipSync.zip"
