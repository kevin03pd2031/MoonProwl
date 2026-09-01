#!/bin/bash
# Build MoonProwl Browser (blue Material UI + privacy layer) for macOS.
# Produces a UNIVERSAL binary (arm64 + x86_64) so it runs on both Apple Silicon
# and Intel Macs. Usage: ./build.sh
set -e
cd "$(dirname "$0")"

APP="build/MoonProwl Browser.app"
BIN="$APP/Contents/MacOS/MoonProwlBrowser"
RES="$APP/Contents/Resources"

mkdir -p "$APP/Contents/MacOS" "$RES" "$APP/Contents/_CodeSignature"

echo "==> Compiling main.swift (universal: arm64 + x86_64)"
mkdir -p build/arm64 build/x86_64
swiftc -O -target arm64-apple-macosx12.0   -framework WebKit -framework Cocoa -o build/arm64/MoonProwlBrowser   main.swift
swiftc -O -target x86_64-apple-macosx12.0 -framework WebKit -framework Cocoa -o build/x86_64/MoonProwlBrowser main.swift
lipo -create -output "$BIN" build/arm64/MoonProwlBrowser build/x86_64/MoonProwlBrowser
lipo -info "$BIN"

echo "==> Copying resources"
cp blocklist.json "$RES/blocklist.json"
cp Info.plist "$APP/Contents/Info.plist"
cp entitlements.plist "$APP/Contents/entitlements.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Use the KevinLightBrowser-style app icon (Material UI, blue).
cp klb_icon.icns "$RES/AppIcon.icns"

echo "==> Codesigning (ad-hoc)"
codesign --force --deep --sign - --entitlements entitlements.plist "$APP"

echo "==> Verifying"
codesign --verify --verbose=2 "$APP" | head -3
echo "DONE -> $APP"
