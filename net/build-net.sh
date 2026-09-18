#!/bin/bash
# Builds the turbo-net helper (tsnet) as a universal macOS binary into net/bin/.
# Both apps' build.sh copy it into their bundle. Needs Go (brew install go).
set -euo pipefail
cd "$(dirname "$0")/turbo-net"
mkdir -p ../bin
GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o ../bin/turbo-net-arm64 .
GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o ../bin/turbo-net-amd64 .
lipo -create ../bin/turbo-net-arm64 ../bin/turbo-net-amd64 -output ../bin/turbo-net
rm -f ../bin/turbo-net-arm64 ../bin/turbo-net-amd64
echo "✅  net/bin/turbo-net ($(lipo -archs ../bin/turbo-net))"
