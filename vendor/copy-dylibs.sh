#!/bin/bash
# The one place that decides which dylibs travel inside an app bundle. Both
# build.sh and receiver/build.sh call it; they used to collect libraries in two
# different ways, and the Receiver silently shipped without libx264/libsrt/…
# (it only ran on Macs that happened to have Homebrew).
#
#   copy-dylibs.sh collect <libdir> <macho>...
#       Copy every non-system dylib the given Mach-O files need, recursively,
#       into <libdir> under its leaf name — the name dyld looks up, because the
#       app launches helpers with DYLD_LIBRARY_PATH=<libdir>.
#
#   copy-dylibs.sh verify <libdir> <bindir>
#       Check that every Mach-O under <bindir> (lib/ included) finds each of its
#       non-system dependencies in <libdir>. Lists what is missing and exits 1,
#       so a bundle that would only work on the build machine never ships.
set -euo pipefail
MODE="${1:-}"; LIB="${2:-}"
[ -n "$MODE" ] && [ -n "$LIB" ] || { echo "usage: $0 collect|verify <libdir> ..." >&2; exit 2; }
shift 2

# Dependency install names, without otool's per-file / per-architecture header lines.
deps() { otool -L "$1" 2>/dev/null | grep -v ':$' | awk '{print $1}'; }
is_system() { case "$1" in /usr/lib/*|/System/*) return 0 ;; esac; return 1; }

case "$MODE" in
collect)
    mkdir -p "$LIB"
    SEEN=" "
    collect() {
        local f="$1" d name
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            is_system "$d" && continue
            case "$d" in /*) ;; *) continue ;; esac   # @rpath/@loader_path: resolved by leaf name, supplied by the caller
            name="$(basename "$d")"
            case "$SEEN" in *" $name "*) continue ;; esac
            SEEN="$SEEN$name "
            if [ ! -f "$d" ]; then
                echo "‼️   $(basename "$f") needs $d, which does not exist on this machine" >&2
                exit 1
            fi
            cp -f "$d" "$LIB/$name"                   # follows symlinks: the content, under the looked-up name
            chmod 755 "$LIB/$name"
            collect "$LIB/$name"
        done < <(deps "$f")
    }
    for m in "$@"; do [ -f "$m" ] && collect "$m"; done
    ;;
verify)
    BIN="${1:-}"
    [ -d "$BIN" ] || { echo "verify: no such directory $BIN" >&2; exit 2; }
    missing=0
    while IFS= read -r -d '' m; do
        file -b "$m" | grep -q 'Mach-O' || continue
        self="$(basename "$m")"
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            is_system "$d" && continue
            name="$(basename "$d")"
            [ "$name" = "$self" ] && continue          # a dylib's own install id
            if [ ! -e "$LIB/$name" ]; then
                echo "‼️   $self needs $name — not in the bundle" >&2
                missing=1
            fi
        done < <(deps "$m")
    done < <(find "$BIN" -type f -print0)
    [ "$missing" -eq 0 ] || { echo "‼️   bundle is not self-contained — refusing to ship it" >&2; exit 1; }
    echo "✅  $(find "$LIB" -maxdepth 1 -name '*.dylib' | wc -l | tr -d ' ') dylibs; every non-system dependency resolves inside the bundle"
    ;;
*) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac
