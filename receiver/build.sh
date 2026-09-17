#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# build.sh — Compile Receiver and package it as a self-contained .app bundle
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Receiver"
BUNDLE="Turbo Receiver.app"
BUILD_DIR=".build/release"

echo "🔨  Building ${APP_NAME}…"
swift build -c release 2>&1
echo ""

echo "📦  Packaging ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/bin"

cp "$BUILD_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE/Contents/MacOS/$APP_NAME"

# ── mediamtx (single static Go binary — no dylibs to bundle) ─────────────────
if [ ! -x vendor/mediamtx ]; then
    echo "⚠️   vendor/mediamtx missing — fetching…"
    ./fetch-mediamtx.sh
fi
cp vendor/mediamtx "$BUNDLE/Contents/Resources/bin/mediamtx"
chmod +x "$BUNDLE/Contents/Resources/bin/mediamtx"
[ -f vendor/mediamtx.LICENSE ] && cp vendor/mediamtx.LICENSE "$BUNDLE/Contents/Resources/" || true
echo "✅  Bundled mediamtx"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Turbo Receiver</string>
    <key>CFBundleDisplayName</key><string>Turbo Receiver</string>
    <key>CFBundleIdentifier</key><string>com.indigital.turboreceiver</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

echo "✍️   Code-signing (ad-hoc)…"
codesign --force --deep -s - "$BUNDLE" 2>&1 | sed 's/^/    /' || true

echo ""
echo "✅  Done!  →  ./${BUNDLE}"
echo "Run with:   open \"${BUNDLE}\""
