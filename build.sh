#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# build.sh — Compile Streamer and package it as a self-contained .app bundle
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="Streamer"
BUNDLE="${APP_NAME}.app"
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
HOMEBREW_FFMPEG="/opt/homebrew/bin/ffmpeg"
HOMEBREW_FFPROBE="/opt/homebrew/bin/ffprobe"
BIN_DST="$BUNDLE/Contents/Resources/bin"
LIB_DST="$BIN_DST/lib"

if [ -f "$HOMEBREW_FFMPEG" ] && file "$HOMEBREW_FFMPEG" | grep -q arm64; then
    echo "✅  Found native arm64 ffmpeg (Homebrew) — bundling with dylibs…"
    mkdir -p "$LIB_DST"

    cp "$HOMEBREW_FFMPEG" "$BIN_DST/ffmpeg"
    [ -f "$HOMEBREW_FFPROBE" ] && cp "$HOMEBREW_FFPROBE" "$BIN_DST/ffprobe" || true
    chmod +x "$BIN_DST/ffmpeg" "$BIN_DST/ffprobe" 2>/dev/null || true

    # Collect and copy all non-system Homebrew dylibs (ffmpeg + its transitive deps)
    COPIED=""
    copy_deps() {
        local BIN="$1"
        [ -f "$BIN" ] || return
        while IFS= read -r LIB; do
            [ -z "$LIB" ] && continue
            LIB_NAME=$(basename "$LIB")
            # Skip if already copied to avoid infinite loops
            echo "$COPIED" | grep -qF "$LIB_NAME" && continue
            COPIED="$COPIED $LIB_NAME"
            cp "$LIB" "$LIB_DST/$LIB_NAME"
            chmod 755 "$LIB_DST/$LIB_NAME"
            # Recurse into this dylib's own deps
            copy_deps "$LIB_DST/$LIB_NAME"
        done < <(otool -L "$BIN" | awk '{print $1}' | grep -E "^/opt/homebrew" || true)
    }
    copy_deps "$BIN_DST/ffmpeg"
    [ -f "$BIN_DST/ffprobe" ] && copy_deps "$BIN_DST/ffprobe" || true

    echo "✅  Bundled $(ls "$LIB_DST" | wc -l | tr -d ' ') dylibs"

elif [ -f "bin/ffmpeg" ]; then
    ARCH=$(file bin/ffmpeg | grep -o 'arm64\|x86_64' || echo 'unknown')
    echo "⚠️   Using ./bin/ffmpeg ($ARCH)"
    cp bin/ffmpeg "$BIN_DST/ffmpeg" && chmod +x "$BIN_DST/ffmpeg"
    [ -f "bin/ffprobe" ] && cp bin/ffprobe "$BIN_DST/ffprobe" && chmod +x "$BIN_DST/ffprobe" || true
else
    echo "⚠️   No ffmpeg found — app will fall back to system ffmpeg."
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
    <key>CFBundleVersion</key><string>2.0</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
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
echo "✍️   Code-signing (ad-hoc)…"
chmod -R u+rw "$BUNDLE"
xattr -rc "$BUNDLE"
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE"

ARCH=$(file "$BIN_DST/ffmpeg" 2>/dev/null | grep -o 'arm64\|x86_64' || echo 'unknown')
echo ""
echo "✅  Done!  →  ./${BUNDLE}  (ffmpeg: ${ARCH})"
echo "Run with:   open ${BUNDLE}"
