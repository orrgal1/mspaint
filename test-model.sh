#!/usr/bin/env bash
#
# Behavioural verification for the Paint document model.
#
# The installed toolchain is Apple CommandLineTools without Xcode, so XCTest
# and Swift Testing are unavailable and `swift test` cannot run. Instead the
# model sources are compiled together with Tests/ModelSmoke.swift into a single
# throwaway executable that exercises the document and exits non-zero on the
# first failed expectation.
#
# Usage: bash test-model.sh

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="$root/.build"
binary="$build_dir/model-smoke"

mkdir -p "$build_dir"

swiftc \
    -swift-version 5 \
    -parse-as-library \
    -framework AppKit \
    -framework CoreGraphics \
    -framework ImageIO \
    -o "$binary" \
    "$root/Sources/PaintMac/PaintTypes.swift" \
    "$root/Sources/PaintMac/PaintShapeGeometry.swift" \
    "$root/Sources/PaintMac/PaintDocument.swift" \
    "$root/Tests/ModelSmoke.swift"

exec "$binary"
