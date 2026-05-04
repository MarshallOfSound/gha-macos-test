#!/bin/bash
set -e
rm -rf Probe.app
mkdir -p Probe.app/Contents/MacOS
cat > Probe.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Probe</string>
  <key>CFBundleIdentifier</key><string>com.example.aeprobe</string>
  <key>CFBundleName</key><string>Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSPrincipalClass</key><string>ProbeApplication</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict></plist>
PLIST
ARCH=${ARCH:-$(uname -m)}
clang -arch "$ARCH" -framework Cocoa -fobjc-arc -o Probe.app/Contents/MacOS/Probe main.m
codesign --force --sign - Probe.app   # ad-hoc; LaunchServices is pickier unsigned
