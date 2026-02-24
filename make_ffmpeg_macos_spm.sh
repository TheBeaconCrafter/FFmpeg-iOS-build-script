#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "--------------------------------------------"
echo "FFmpeg macOS Swift Package Generator"
echo "--------------------------------------------"

usage() {
  cat <<USAGE
Usage: ./make_ffmpeg_macos_spm.sh [--rebuild] [--ffmpeg-version <ver>] [--pkg-dir <dir>] [package_dir]

Options:
  --rebuild         Rebuild FFmpeg macOS libs before generating the SPM package.
  --ffmpeg-version  FFmpeg version to build/package (default: 3.4).
  --pkg-dir <dir>   Output package directory (default: FFmpegMacOS-SPM).
  -h, --help        Show this help.
USAGE
}

REBUILD_FFMPEG=0
PKG_DIR="FFmpegMacOS-SPM"
FFMPEG_VERSION="${FFMPEG_VERSION:-3.4}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      REBUILD_FFMPEG=1
      shift
      ;;
    --pkg-dir)
      if [[ $# -lt 2 ]]; then
        echo "Error: --pkg-dir requires a value"
        exit 1
      fi
      PKG_DIR="$2"
      shift 2
      ;;
    --ffmpeg-version)
      if [[ $# -lt 2 ]]; then
        echo "Error: --ffmpeg-version requires a value"
        exit 1
      fi
      FFMPEG_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$1" == -* ]]; then
        echo "Error: Unknown option '$1'"
        usage
        exit 1
      fi
      PKG_DIR="$1"
      shift
      ;;
  esac
done

# -------- configuration --------
MAC_DIR="FFmpeg-macOS"
HEADERS_DIR="$MAC_DIR/include"
OUT_XCF_DIR="$PKG_DIR/Frameworks"
TMP_HEADERS_DIR="$PKG_DIR/.headers"
TMP_LIB_DIR="$PKG_DIR/.tmp"
FFMPEG_SRC_DIR="$SCRIPT_DIR/ffmpeg-$FFMPEG_VERSION"
BUILD_SCRIPT="$SCRIPT_DIR/build-ffmpeg-macos.sh"

LIBS=(
  libavcodec
  libavdevice
  libavfilter
  libavformat
  libavutil
  libswresample
  libswscale
)

ensure_ffmpeg_source_tree() {
  if [[ -d "$FFMPEG_SRC_DIR" ]]; then
    return
  fi

  local archive="ffmpeg-$FFMPEG_VERSION.tar.bz2"
  local url="https://ffmpeg.org/releases/$archive"
  echo "FFmpeg source tree not found at $FFMPEG_SRC_DIR"
  echo "Downloading $url ..."
  curl -L "$url" | tar xj
}

prune_unsupported_headers() {
  rm -f "$HEADERS_ROOT/libavcodec/d3d11va.h" \
        "$HEADERS_ROOT/libavcodec/dxva2.h" \
        "$HEADERS_ROOT/libavcodec/jni.h" \
        "$HEADERS_ROOT/libavcodec/qsv.h" \
        "$HEADERS_ROOT/libavcodec/vaapi.h" \
        "$HEADERS_ROOT/libavcodec/vda.h" \
        "$HEADERS_ROOT/libavcodec/vdpau.h" \
        "$HEADERS_ROOT/libavcodec/xvmc.h"

  rm -f "$HEADERS_ROOT/libavutil/hwcontext_vulkan.h" \
        "$HEADERS_ROOT/libavutil/hwcontext_vdpau.h" \
        "$HEADERS_ROOT/libavutil/hwcontext_vaapi.h" \
        "$HEADERS_ROOT/libavutil/hwcontext_qsv.h" \
        "$HEADERS_ROOT/libavutil/hwcontext_opencl.h" \
        "$HEADERS_ROOT/libavutil/hwcontext_dxva2.h" \
        "$HEADERS_ROOT/libavutil/hwcontext_d3d11va.h" \
        "$HEADERS_ROOT/libavutil/hwcontext_cuda.h"
}

if [[ "$REBUILD_FFMPEG" -eq 1 ]]; then
  ensure_ffmpeg_source_tree

  export FFMPEG_VERSION
  export SOURCE="ffmpeg-$FFMPEG_VERSION"

  if [[ ! -x "$BUILD_SCRIPT" ]]; then
    echo "Error: Build script not found or not executable: $BUILD_SCRIPT"
    exit 1
  fi

  echo "Rebuilding FFmpeg macOS libraries..."
  "$BUILD_SCRIPT"
fi

# -------- validation --------
echo "Validating build outputs..."

if [[ ! -d "$MAC_DIR/lib" ]]; then
  echo "Error: Missing directory $MAC_DIR/lib"
  echo "Run ./build-ffmpeg-macos.sh lipo first (or use --rebuild)."
  exit 1
fi

if [[ ! -d "$HEADERS_DIR" ]]; then
  echo "Error: Missing headers at $HEADERS_DIR"
  exit 1
fi

for name in "${LIBS[@]}"; do
  if [[ ! -f "$MAC_DIR/lib/${name}.a" ]]; then
    echo "Error: Missing $MAC_DIR/lib/${name}.a"
    exit 1
  fi
done

echo "Validation complete."

# -------- prepare package --------
echo "Preparing package structure..."

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/Sources/FFmpegMacOSSupport"
mkdir -p "$OUT_XCF_DIR"
mkdir -p "$TMP_HEADERS_DIR"
mkdir -p "$TMP_LIB_DIR"

# Build one merged static archive to avoid duplicate-header collisions across targets.
MERGED_LIB="$TMP_LIB_DIR/libffmpeg.a"
LIB_INPUTS=()
for name in "${LIBS[@]}"; do
  LIB_INPUTS+=("$MAC_DIR/lib/${name}.a")
done

libtool -static -o "$MERGED_LIB" "${LIB_INPUTS[@]}"

HEADERS_ROOT="$TMP_HEADERS_DIR/mac_ffmpeg"
mkdir -p "$HEADERS_ROOT"
cp -R "$HEADERS_DIR/." "$HEADERS_ROOT/"
prune_unsupported_headers

cat > "$HEADERS_ROOT/module.modulemap" <<'MAP'
module mac_ffmpeg {
    umbrella "."
    export *
}
MAP

echo "Creating XCFramework..."
xcodebuild -create-xcframework \
  -library "$MERGED_LIB" -headers "$HEADERS_ROOT" \
  -output "$OUT_XCF_DIR/mac_ffmpeg.xcframework" >/dev/null

echo "XCFramework creation complete."

# -------- Package.swift --------
echo "Generating Package.swift..."

cat > "$PKG_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FFmpegMacOS",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "FFmpegMacOSSupport", targets: ["FFmpegMacOSSupport"]),
    ],
    targets: [
        .binaryTarget(name: "mac_ffmpeg", path: "Frameworks/mac_ffmpeg.xcframework"),
        .target(
            name: "FFmpegMacOSSupport",
            dependencies: ["mac_ffmpeg"]
        ),
    ]
)
SWIFT

# -------- wrapper source --------
cat > "$PKG_DIR/Sources/FFmpegMacOSSupport/FFmpegSupport.swift" <<'SWIFT'
@_exported import Foundation

/*
 This target links the FFmpeg binary libraries.
*/
SWIFT

echo "--------------------------------------------"
echo "Package successfully generated."
echo "Location: $PKG_DIR"
echo "Product: FFmpegMacOSSupport"
echo "--------------------------------------------"
