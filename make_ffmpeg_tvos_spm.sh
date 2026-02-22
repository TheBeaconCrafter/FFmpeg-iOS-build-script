#!/usr/bin/env bash
set -euo pipefail

echo "--------------------------------------------"
echo "FFmpeg tvOS Swift Package Generator"
echo "--------------------------------------------"

# -------- configuration --------
PKG_DIR="${1:-FFmpegTVOS-SPM}"
DEVICE_DIR="FFmpeg-tvOS"
SIM_DIR="FFmpeg-tvOS-sim"
HEADERS_DIR="$DEVICE_DIR/include"
OUT_XCF_DIR="$PKG_DIR/Frameworks"

LIBS=(
  libavcodec
  libavdevice
  libavfilter
  libavformat
  libavutil
  libswresample
  libswscale
)

# -------- validation --------
echo "Validating build outputs..."

for d in "$DEVICE_DIR" "$SIM_DIR"; do
  if [[ ! -d "$d/lib" ]]; then
    echo "Error: Missing directory $d/lib"
    echo "Run ./build-ffmpeg-tvos.sh lipo first."
    exit 1
  fi
done

if [[ ! -d "$HEADERS_DIR" ]]; then
  echo "Error: Missing headers at $HEADERS_DIR"
  exit 1
fi

echo "Validation complete."

# -------- prepare package --------
echo "Preparing package structure..."

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/Sources/FFmpegSupport"
mkdir -p "$OUT_XCF_DIR"

echo "Package directory: $PKG_DIR"

# -------- create XCFrameworks --------
echo "Creating XCFrameworks..."

for name in "${LIBS[@]}"; do
  DEV_LIB="$DEVICE_DIR/lib/${name}.a"
  SIM_LIB="$SIM_DIR/lib/${name}.a"

  if [[ ! -f "$DEV_LIB" ]]; then
    echo "Error: Missing $DEV_LIB"
    exit 1
  fi

  if [[ ! -f "$SIM_LIB" ]]; then
    echo "Error: Missing $SIM_LIB"
    exit 1
  fi

  echo "Processing $name"

  xcodebuild -create-xcframework \
    -library "$DEV_LIB" -headers "$HEADERS_DIR" \
    -library "$SIM_LIB" -headers "$HEADERS_DIR" \
    -output "$OUT_XCF_DIR/${name}.xcframework" >/dev/null

done

echo "XCFramework creation complete."

# -------- Package.swift --------
echo "Generating Package.swift..."

cat > "$PKG_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FFmpegTVOS",
    platforms: [
        .tvOS(.v13)
    ],
    products: [
        .library(name: "FFmpegSupport", targets: ["FFmpegSupport"]),
    ],
    targets: [
        .binaryTarget(name: "libavcodec", path: "Frameworks/libavcodec.xcframework"),
        .binaryTarget(name: "libavdevice", path: "Frameworks/libavdevice.xcframework"),
        .binaryTarget(name: "libavfilter", path: "Frameworks/libavfilter.xcframework"),
        .binaryTarget(name: "libavformat", path: "Frameworks/libavformat.xcframework"),
        .binaryTarget(name: "libavutil", path: "Frameworks/libavutil.xcframework"),
        .binaryTarget(name: "libswresample", path: "Frameworks/libswresample.xcframework"),
        .binaryTarget(name: "libswscale", path: "Frameworks/libswscale.xcframework"),

        .target(
            name: "FFmpegSupport",
            dependencies: [
                "libavcodec",
                "libavdevice",
                "libavfilter",
                "libavformat",
                "libavutil",
                "libswresample",
                "libswscale"
            ]
        ),
    ]
)
SWIFT

echo "Package.swift created."

# -------- wrapper source --------
echo "Creating wrapper source..."

cat > "$PKG_DIR/Sources/FFmpegSupport/FFmpegSupport.swift" <<'SWIFT'
@_exported import Foundation

/*
 This target links the FFmpeg binary libraries.

 Add C wrappers or Swift helpers here if needed.
*/
SWIFT

echo "Wrapper source created."

echo "--------------------------------------------"
echo "Package successfully generated."
echo "Location: $PKG_DIR"
echo ""
echo "To use in Xcode:"
echo "1. File → Add Packages → Add Local"
echo "2. Select $PKG_DIR"
echo "3. Link FFmpegSupport to your tvOS target"
echo "--------------------------------------------"
