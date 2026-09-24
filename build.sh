#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# build.sh — Compile Streamer and package it as a self-contained .app bundle
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="Streamer"
BUNDLE="Turbo Streamer.app"   # the executable inside stays "Streamer"
ENTITLEMENTS="Streamer.entitlements"
BUILD_DIR=".build/release"

echo "🔨  Building ${APP_NAME}…"
swift build -c release 2>&1
echo ""

echo "📦  Packaging ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources/bin"

# Swift binary
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE/Contents/MacOS/$APP_NAME"

# ── ffmpeg ───────────────────────────────────────────────────────────────────
# Prefer native arm64 Homebrew ffmpeg.  The app sets DYLD_LIBRARY_PATH at
# runtime so the bundled dylibs are found without any path rewriting.
BIN_DST="$BUNDLE/Contents/Resources/bin"
LIB_DST="$BIN_DST/lib"

# Pick an ffmpeg that actually RUNS and is fit for this app. Three traps here,
# all of which have already bitten:
#   1. Homebrew's can be installed but broken (missing dylibs), so test execution.
#   2. "$BUNDLE" is deleted above, so it must NEVER be a candidate source — an
#      earlier version listed it and silently fell through to a stale x86_64
#      copy in ./bin.
#   3. An ffmpeg without libsrt/decklink builds fine and then fails at runtime,
#      so require the features this app actually uses.
FFMPEG_SRC=""
ffmpeg_is_fit() {
    local c="$1"
    [ -x "$c/ffmpeg" ] || return 1
    file "$c/ffmpeg" | grep -q 'arm64' || return 1
    DYLD_LIBRARY_PATH="$c/lib" "$c/ffmpeg" -version >/dev/null 2>&1 || return 1
    local cfg
    cfg=$(DYLD_LIBRARY_PATH="$c/lib" "$c/ffmpeg" -hide_banner -version 2>/dev/null)
    echo "$cfg" | grep -q -- '--enable-libsrt' || return 1
    echo "$cfg" | grep -q -- '--enable-libx264' || return 1
    echo "$cfg" | grep -q -- '--enable-decklink' || return 1
    return 0
}
for c in "vendor/bin" "/opt/homebrew/bin"; do
    if ffmpeg_is_fit "$c"; then FFMPEG_SRC="$c"; break; fi
done
if [ -z "$FFMPEG_SRC" ]; then
    echo "‼️   No suitable ffmpeg found (need arm64 with --enable-libsrt, --enable-libx264 and --enable-decklink)."
    echo "    Checked: vendor/bin, /opt/homebrew/bin."
    echo "    Refusing to bundle an unfit binary — SRT output and DeckLink would break at runtime."
    echo "    Fix Homebrew's ffmpeg, or place a good one in vendor/bin/, then re-run."
    exit 1
fi
HOMEBREW_FFMPEG="$FFMPEG_SRC/ffmpeg"
HOMEBREW_FFPROBE="$FFMPEG_SRC/ffprobe"

echo "✅  ffmpeg from $FFMPEG_SRC — bundling with its dylibs…"
mkdir -p "$LIB_DST"
cp "$HOMEBREW_FFMPEG" "$BIN_DST/ffmpeg"
[ -f "$HOMEBREW_FFPROBE" ] && cp "$HOMEBREW_FFPROBE" "$BIN_DST/ffprobe" || true
chmod +x "$BIN_DST/ffmpeg" "$BIN_DST/ffprobe" 2>/dev/null || true
# A pre-assembled set (vendor/bin/lib) goes in as-is; either way the shared helper
# then pulls in every transitive non-system dylib (verified before signing, below).
[ -d "$FFMPEG_SRC/lib" ] && cp -R "$FFMPEG_SRC/lib/." "$LIB_DST/" || true
./vendor/copy-dylibs.sh collect "$LIB_DST" "$BIN_DST/ffmpeg" "$BIN_DST/ffprobe"

# ── mediamtx + NDI (embedded LAN server: publish the feed on the local network) ─
# Reuse the artifacts the Receiver already builds.
if [ -x receiver/vendor/mediamtx ]; then
    cp receiver/vendor/mediamtx "$BIN_DST/mediamtx" && chmod +x "$BIN_DST/mediamtx"
    [ -f receiver/vendor/mediamtx.LICENSE ] && cp receiver/vendor/mediamtx.LICENSE "$BUNDLE/Contents/Resources/" || true
    echo "✅  Bundled mediamtx"
else
    echo "⚠️   receiver/vendor/mediamtx missing — LAN publishing unavailable (run receiver/fetch-mediamtx.sh)"
fi
if [ -x receiver/ndi/bin/ndi-sender ]; then
    cp receiver/ndi/bin/ndi-sender receiver/ndi/bin/ndi-find "$BIN_DST/" 2>/dev/null || cp receiver/ndi/bin/ndi-sender "$BIN_DST/"
    chmod +x "$BIN_DST/ndi-sender" 2>/dev/null || true
    # The newest libndi on this Mac: the SDK's, once receiver/ndi/ndi-sdk.sh installed it.
    if NDI_LIB="$(receiver/ndi/ndi-sdk.sh lib)"; then
        mkdir -p "$BIN_DST/lib"; cp "$NDI_LIB" "$BIN_DST/lib/libndi.dylib"
        for l in "$(dirname "$NDI_LIB")/libndi_licenses.txt" /usr/local/lib/libndi_licenses.txt; do
            if [ -f "$l" ]; then cp "$l" "$BUNDLE/Contents/Resources/"; break; fi
        done
        echo "✅  Bundled ndi-sender + NDI runtime ($NDI_LIB)"
    else
        echo "✅  Bundled ndi-sender (NDI runtime not found — needs NDI Tools on the target)"
    fi
    receiver/ndi/ndi-sdk.sh check || true   # speaks up when NDI has published a newer SDK
fi

# ── turbo-net (embedded Tailscale node, tsnet) ─────────────────────────────
if [ -x net/bin/turbo-net ] || [ -x ../net/bin/turbo-net ]; then
    SRC=$([ -x net/bin/turbo-net ] && echo net/bin/turbo-net || echo ../net/bin/turbo-net)
    cp "$SRC" "$BIN_DST/turbo-net" && chmod +x "$BIN_DST/turbo-net"
    echo "✅  Bundled turbo-net ($(lipo -archs "$BIN_DST/turbo-net"))"
else
    echo "⚠️   net/bin/turbo-net missing (run net/build-net.sh) — Turbo network unavailable in this build"
fi

# App icon + logos
[ -f "Resources/AppIcon.icns" ] && cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns" || true
[ -f "Resources/indigital-logo.png" ] && cp Resources/indigital-logo.png "$BUNDLE/Contents/Resources/indigital-logo.png" || true

# Fonts
if [ -d "Resources/Fonts" ]; then
    mkdir -p "$BUNDLE/Contents/Resources/Fonts"
    cp Resources/Fonts/*.otf "$BUNDLE/Contents/Resources/Fonts/" 2>/dev/null || true
    cp Resources/Fonts/*.ttf "$BUNDLE/Contents/Resources/Fonts/" 2>/dev/null || true
    echo "✅  Bundled $(ls "$BUNDLE/Contents/Resources/Fonts" | wc -l | tr -d ' ') fonts"
fi

# Info.plist
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Turbo Streamer</string>
    <key>CFBundleDisplayName</key><string>Turbo Streamer</string>
    <key>CFBundleIdentifier</key><string>com.jacopocerati.turbostreamer</string>
    <key>CFBundleVersion</key><string>__BUILD__</string>
    <key>CFBundleShortVersionString</key><string>__SHORT__</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Streamer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCameraUsageDescription</key>
    <string>Streamer uses the camera to stream from a connected capture card.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Streamer uses the microphone to stream audio from a connected capture card.</string>
</dict>
</plist>
PLIST

echo ""
# Version + build stamped from the VERSION file and git (single source of truth).
SHORT_VERSION="$(cat ./VERSION 2>/dev/null || echo 3.0)"
BUILD_NUMBER="$(git -C . rev-list --count HEAD 2>/dev/null || echo 0)"
/usr/bin/sed -i '' "s/__SHORT__/$SHORT_VERSION/; s/__BUILD__/$BUILD_NUMBER/" "$BUNDLE/Contents/Info.plist"
echo "🏷  Version $SHORT_VERSION (build $BUILD_NUMBER)"

# Every helper must find its libraries inside the bundle, not in Homebrew.
./vendor/copy-dylibs.sh verify "$LIB_DST" "$BIN_DST"

echo "✍️   Code-signing (ad-hoc)…"
chmod -R u+rw "$BUNDLE"
xattr -rc "$BUNDLE"
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE"

ARCH=$(file "$BIN_DST/ffmpeg" 2>/dev/null | grep -o 'arm64\|x86_64' || echo 'unknown')
echo ""
echo "✅  Done!  →  ./${BUNDLE}  (ffmpeg: ${ARCH})"
echo "Run with:   open \"${BUNDLE}\""
