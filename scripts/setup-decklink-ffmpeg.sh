#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-decklink-ffmpeg.sh
#
# Builds a DeckLink-enabled ffmpeg (for Blackmagic capture devices) and makes it
# the active Homebrew ffmpeg, so ./build.sh bundles it into Turbo Streamer.
#
# The stock Homebrew ffmpeg is NOT compiled with DeckLink support. This script:
#   1. Copies the Blackmagic SDK headers + dispatch sources into Homebrew's include dir
#   2. Patches in the base COM `IID_IUnknown` symbol (Blackmagic SDK 12+ dropped it,
#      but ffmpeg's decklink code still references it)
#   3. Rebuilds ffmpeg from the homebrew-ffmpeg tap with --with-decklink
#
# PREREQUISITES
#   • Install "Desktop Video" on the machine (the runtime driver) — and make sure
#     its version is >= the SDK version you build against, or capture will refuse
#     to open the device.  https://www.blackmagicdesign.com/support
#   • Download the "Desktop Video SDK" (developer package, NOT the driver):
#     https://www.blackmagicdesign.com/developer/product/capture-and-playback
#     Unzip it; the headers live in:  <SDK>/Mac/include
#
# USAGE
#   bash scripts/setup-decklink-ffmpeg.sh "/path/to/Blackmagic DeckLink SDK XX.Y/Mac/include"
#
# After it finishes, run ./build.sh to rebuild Streamer.app with DeckLink support.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SDK_INCLUDE="${1:-}"

if [ -z "$SDK_INCLUDE" ] || [ ! -f "$SDK_INCLUDE/DeckLinkAPI.h" ]; then
    echo "❌  Could not find DeckLinkAPI.h."
    echo ""
    echo "Usage:"
    echo "  bash scripts/setup-decklink-ffmpeg.sh \"/path/to/Blackmagic DeckLink SDK XX.Y/Mac/include\""
    echo ""
    echo "Download the Desktop Video SDK from:"
    echo "  https://www.blackmagicdesign.com/developer/product/capture-and-playback"
    exit 1
fi

BREW_INC="$(brew --prefix)/include"

echo "📂  Copying SDK headers + dispatch sources → $BREW_INC"
cp "$SDK_INCLUDE"/*.h   "$BREW_INC"/
cp "$SDK_INCLUDE"/*.cpp "$BREW_INC"/

echo "🩹  Ensuring IID_IUnknown is defined (required by ffmpeg, dropped in SDK 12+)…"
python3 - "$BREW_INC/DeckLinkAPI.h" <<'PY'
import sys
path = sys.argv[1]
src  = open(path).read()
if "IID_IUnknown" in src:
    print("    already present — no patch needed")
else:
    marker = "// Interface ID Declarations"
    inject = (marker +
        "\n\n#ifndef IID_IUnknown_DEFINED\n"
        "#define IID_IUnknown_DEFINED\n"
        "BMD_CONST REFIID IID_IUnknown = "
        "{ 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,"
        "0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46 };\n"
        "#endif\n")
    if marker not in src:
        sys.exit("    ⚠️  Could not find injection marker in DeckLinkAPI.h")
    open(path, "w").write(src.replace(marker, inject, 1))
    print("    patched IID_IUnknown")
PY

echo "🍺  Installing DeckLink-enabled ffmpeg (compiles from source, ~2 min)…"
brew tap homebrew-ffmpeg/ffmpeg
brew uninstall --ignore-dependencies ffmpeg 2>/dev/null || true
brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-decklink

echo ""
echo "✅  ffmpeg now has DeckLink support:"
"$(brew --prefix)/bin/ffmpeg" -hide_banner -devices 2>&1 | grep -i decklink || true
echo ""
echo "Next:  bash build.sh    # bundles this ffmpeg into Streamer.app"
