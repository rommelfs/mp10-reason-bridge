#!/bin/zsh
set -eu
cd -- "$(dirname -- "$0")"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/mp10-bridge.XXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT
app="MP10 Reason Bridge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -target "$arch-apple-macosx13.0" -module-cache-path "$build_dir/cache-$arch" -O Bridge.swift -o "$build_dir/bridge-$arch" -framework Cocoa -framework CoreMIDI
done
xcrun lipo -create "$build_dir/bridge-arm64" "$build_dir/bridge-x86_64" -output "$app/Contents/MacOS/MP10ReasonBridge"
xcrun swiftc -module-cache-path "$build_dir/icon-cache" Tools/IconBuilder.swift -o "$build_dir/icon-builder"
"$build_dir/icon-builder" Assets/AppIcon.png "$build_dir/AppIcon.iconset" "$app/Contents/Resources/MenuBarIcon.pdf" "$app/Contents/Resources/AppIcon.icns"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
"$app/Contents/MacOS/MP10ReasonBridge" --self-test
printf 'Built: %s/%s\n' "$PWD" "$app"
