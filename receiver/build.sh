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
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns" && echo "Bundled app icon" || true
# Fonts (shared with Turbo Streamer — Bello Pro for the title, Sofia Pro for the rest).
if [ -d "../Resources/Fonts" ]; then
    mkdir -p "$BUNDLE/Contents/Resources/Fonts"
    cp ../Resources/Fonts/*.otf "$BUNDLE/Contents/Resources/Fonts/" 2>/dev/null || true
    cp ../Resources/Fonts/*.ttf "$BUNDLE/Contents/Resources/Fonts/" 2>/dev/null || true
    echo "Bundled $(ls "$BUNDLE/Contents/Resources/Fonts" | wc -l | tr -d ' ') fonts"
fi

cp vendor/mediamtx "$BUNDLE/Contents/Resources/bin/mediamtx"
chmod +x "$BUNDLE/Contents/Resources/bin/mediamtx"
[ -f vendor/mediamtx.LICENSE ] && cp vendor/mediamtx.LICENSE "$BUNDLE/Contents/Resources/" || true
echo "✅  Bundled mediamtx"

# ── ffmpeg/ffprobe (needed only for the NDI bridge) ─────────────────────────
# The same ffmpeg Turbo Streamer bundles (Homebrew's), with every dylib it needs.
BIN_DST="$BUNDLE/Contents/Resources/bin"
SRC_BIN=""
for c in "../vendor/bin" "/opt/homebrew/bin"; do
    # Must exist AND actually run — a Homebrew ffmpeg can be installed but broken
    # (missing libass), so a plain -x test is not enough.
    if [ -x "$c/ffmpeg" ] && DYLD_LIBRARY_PATH="$c/lib" "$c/ffmpeg" -version >/dev/null 2>&1; then
        SRC_BIN="$c"; break
    fi
done
if [ -n "$SRC_BIN" ]; then
    cp "$SRC_BIN/ffmpeg" "$BIN_DST/ffmpeg"
    [ -x "$SRC_BIN/ffprobe" ] && cp "$SRC_BIN/ffprobe" "$BIN_DST/ffprobe" || true
    chmod +x "$BIN_DST/ffmpeg" "$BIN_DST/ffprobe" 2>/dev/null || true
    [ -d "$SRC_BIN/lib" ] && mkdir -p "$BIN_DST/lib" && cp -R "$SRC_BIN/lib/." "$BIN_DST/lib/" || true
    # Same helper as the Streamer: ffmpeg's libav* AND everything they pull in
    # (x264, srt, …). Copying libav* alone left the rest behind, and the Receiver
    # ran only on Macs that happened to have Homebrew.
    ../vendor/copy-dylibs.sh collect "$BIN_DST/lib" "$BIN_DST/ffmpeg" "$BIN_DST/ffprobe"
    echo "✅  Bundled ffmpeg from $SRC_BIN"
else
    echo "⚠️   ffmpeg not found — NDI output will be unavailable"
fi

# ── turbo-net (embedded Tailscale node, tsnet) ─────────────────────────────
if [ -x net/bin/turbo-net ] || [ -x ../net/bin/turbo-net ]; then
    SRC=$([ -x net/bin/turbo-net ] && echo net/bin/turbo-net || echo ../net/bin/turbo-net)
    cp "$SRC" "$BIN_DST/turbo-net" && chmod +x "$BIN_DST/turbo-net"
    echo "✅  Bundled turbo-net ($(lipo -archs "$BIN_DST/turbo-net"))"
else
    echo "⚠️   net/bin/turbo-net missing (run net/build-net.sh) — Turbo network unavailable in this build"
fi

# ── NDI bridge binaries ─────────────────────────────────────────────────────
if [ -x ndi/bin/ndi-sender ]; then
    cp ndi/bin/ndi-sender ndi/bin/ndi-find "$BIN_DST/" 2>/dev/null || cp ndi/bin/ndi-sender "$BIN_DST/"
    chmod +x "$BIN_DST/ndi-sender" 2>/dev/null || true
    echo "✅  Bundled ndi-sender"
    # NDI runtime bundled too, so the app runs without installing NDI Tools: the
    # newest libndi on this Mac (the SDK's, once ndi/ndi-sdk.sh has installed it).
    if NDI_LIB="$(ndi/ndi-sdk.sh lib)"; then
        mkdir -p "$BIN_DST/lib"
        cp "$NDI_LIB" "$BIN_DST/lib/libndi.dylib"
        for l in "$(dirname "$NDI_LIB")/libndi_licenses.txt" /usr/local/lib/libndi_licenses.txt; do
            if [ -f "$l" ]; then cp "$l" "$BUNDLE/Contents/Resources/"; break; fi
        done
        echo "✅  Bundled NDI runtime ($NDI_LIB)"
    else
        echo "⚠️   NDI runtime not found — app will need NDI Tools installed"
    fi
    ndi/ndi-sdk.sh check || true   # speaks up when NDI has published a newer SDK
else
    echo "⚠️   ndi/bin/ndi-sender missing — run ndi/build-ndi.sh (needs NDI SDK headers)"
fi

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
    <key>CFBundleShortVersionString</key><string>__SHORT__</string>
    <key>CFBundleVersion</key><string>__BUILD__</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

# Version + build stamped from the VERSION file and git (single source of truth).
SHORT_VERSION="$(cat ../VERSION 2>/dev/null || echo 3.0)"
BUILD_NUMBER="$(git -C .. rev-list --count HEAD 2>/dev/null || echo 0)"
/usr/bin/sed -i '' "s/__SHORT__/$SHORT_VERSION/; s/__BUILD__/$BUILD_NUMBER/" "$BUNDLE/Contents/Info.plist"
echo "🏷  Version $SHORT_VERSION (build $BUILD_NUMBER)"

echo "✍️   Code-signing (ad-hoc)…"
# Every helper must find its libraries inside the bundle, not in Homebrew.
if [ -d "$BIN_DST/lib" ]; then ../vendor/copy-dylibs.sh verify "$BIN_DST/lib" "$BIN_DST"; fi
codesign --force --deep -s - "$BUNDLE" 2>&1 | sed 's/^/    /' || true

echo ""
echo "✅  Done!  →  ./${BUNDLE}"
echo "Run with:   open \"${BUNDLE}\""
