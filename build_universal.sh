#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# build_universal.sh — Build a universal (arm64 + x86_64) Streamer.app bundle
#
# IMPORTANT: Run this from Terminal.app (not from an IDE or Claude Code).
# The first run installs x86_64 Homebrew + ffmpeg and will ask for your
# password. After that one-time setup, subsequent runs need no sudo.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="Streamer"
BUNDLE="${APP_NAME}.app"
ENTITLEMENTS="Streamer.entitlements"
BIN_DST="$BUNDLE/Contents/Resources/bin"
LIB_DST="$BIN_DST/lib"

ARM64_FFMPEG="/opt/homebrew/bin/ffmpeg"
ARM64_FFPROBE="/opt/homebrew/bin/ffprobe"
X86_BREW="/usr/local/bin/brew"
X86_FFMPEG="/usr/local/bin/ffmpeg"
X86_FFPROBE="/usr/local/bin/ffprobe"

# ── Step 1: compile both architectures ───────────────────────────────────────
# Build x86_64 first so arm64 build is last — build.sh's swift build then
# finds a clean arm64 state and .build/release/ symlinks to arm64.
echo "🔨  Compiling x86_64 Swift binary (via Rosetta)…"
swift package clean 2>/dev/null || true
arch -x86_64 swift build -c release 2>&1 | grep -v "^warning:"

echo "🔨  Compiling arm64 Swift binary…"
swift build -c release 2>&1 | grep -v "^warning:"
echo ""

# ── Step 1b: package base bundle, then lipo the Swift binary in-place ─────────
echo "📦  Packaging base bundle…"
bash build.sh

lipo -create \
    ".build/arm64-apple-macosx/release/${APP_NAME}" \
    ".build/x86_64-apple-macosx/release/${APP_NAME}" \
    -output "$BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE/Contents/MacOS/$APP_NAME"
echo "✅  Swift binary: $(lipo -archs "$BUNDLE/Contents/MacOS/$APP_NAME")"
echo ""

# ── Step 2: ensure x86_64 Homebrew ───────────────────────────────────────────
if [ ! -f "$X86_BREW" ]; then
    echo "📥  Installing x86_64 Homebrew (via Rosetta) — follow the prompts…"
    arch -x86_64 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo ""
fi

# ── Step 3: ensure x86_64 ffmpeg ─────────────────────────────────────────────
if [ ! -f "$X86_FFMPEG" ]; then
    echo "📥  Installing x86_64 ffmpeg…"
    arch -x86_64 "$X86_BREW" install ffmpeg
    echo ""
fi

echo "🔀  Merging arm64 + x86_64 into universal bundle…"

# ── Step 4: collect x86_64 dylibs into a temp dir ────────────────────────────
X86_LIB_TMP=$(mktemp -d)

collect_x86_deps() {
    local BIN="$1"
    [ -f "$BIN" ] || return
    while IFS= read -r LIB; do
        [ -z "$LIB" ] && continue
        LIB_NAME=$(basename "$LIB")
        [ -f "$X86_LIB_TMP/$LIB_NAME" ] && continue
        cp "$LIB" "$X86_LIB_TMP/$LIB_NAME"
        chmod 755 "$X86_LIB_TMP/$LIB_NAME"
        collect_x86_deps "$X86_LIB_TMP/$LIB_NAME"
    done < <(otool -L "$BIN" | awk '{print $1}' | grep -E "^/usr/local" || true)
}

collect_x86_deps "$X86_FFMPEG"
[ -f "$X86_FFPROBE" ] && collect_x86_deps "$X86_FFPROBE" || true
echo "✅  Collected $(ls "$X86_LIB_TMP" | wc -l | tr -d ' ') x86_64 dylibs"

# ── Step 5: lipo ffmpeg (and ffprobe) ────────────────────────────────────────
lipo -create "$ARM64_FFMPEG" "$X86_FFMPEG" -output "$BIN_DST/ffmpeg"
chmod +x "$BIN_DST/ffmpeg"

if [ -f "$BIN_DST/ffprobe" ] && [ -f "$X86_FFPROBE" ]; then
    lipo -create "$ARM64_FFPROBE" "$X86_FFPROBE" -output "$BIN_DST/ffprobe"
    chmod +x "$BIN_DST/ffprobe"
fi
echo "✅  Universal ffmpeg: $(lipo -archs "$BIN_DST/ffmpeg")"

# ── Step 6: lipo each dylib ───────────────────────────────────────────────────
LIPO_OK=0
LIPO_SKIP=0

for ARM_LIB in "$LIB_DST"/*.dylib; do
    LIB_NAME=$(basename "$ARM_LIB")
    X86_LIB="$X86_LIB_TMP/$LIB_NAME"
    if [ -f "$X86_LIB" ]; then
        lipo -create "$ARM_LIB" "$X86_LIB" -output "$ARM_LIB"
        LIPO_OK=$((LIPO_OK + 1))
    else
        LIPO_SKIP=$((LIPO_SKIP + 1))
        echo "  ⚠  No x86_64 match for $LIB_NAME — left as arm64-only"
    fi
done

echo "✅  Universalized $LIPO_OK dylibs  ($LIPO_SKIP arm64-only)"

# ── Step 7: cleanup ───────────────────────────────────────────────────────────
rm -rf "$X86_LIB_TMP"

# ── Step 8: re-sign the universal bundle ─────────────────────────────────────
echo ""
echo "✍️   Re-signing universal bundle…"
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE"

echo ""
echo "✅  Done!  →  ./${BUNDLE}"
echo "    ffmpeg architectures: $(lipo -archs "$BIN_DST/ffmpeg")"
echo "Run with:   open ${BUNDLE}"
