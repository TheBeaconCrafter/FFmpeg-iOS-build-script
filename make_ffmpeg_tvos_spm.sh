#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "--------------------------------------------"
echo "FFmpeg tvOS Swift Package Generator"
echo "--------------------------------------------"

usage() {
  cat <<USAGE
Usage: ./make_ffmpeg_tvos_spm.sh [--rebuild] [--ffmpeg-version <ver>] [--pkg-dir <dir>] [package_dir]

Options:
  --rebuild         Rebuild FFmpeg tvOS libs before generating the SPM package.
  --ffmpeg-version  FFmpeg version to build/package (default: 3.4).
  --pkg-dir <dir>   Output package directory (default: FFmpegTVOS-SPM).
  -h, --help        Show this help.

Notes:
  --rebuild applies tvOS compatibility patches for FFmpeg SecureTransport
  so HTTPS input works on tvOS SDKs where older APIs are unavailable.
USAGE
}

REBUILD_FFMPEG=0
PKG_DIR="FFmpegTVOS-SPM"
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
DEVICE_DIR="FFmpeg-tvOS"
SIM_DIR="FFmpeg-tvOS-sim"
HEADERS_DIR="$DEVICE_DIR/include"
OUT_XCF_DIR="$PKG_DIR/Frameworks"
TMP_HEADERS_DIR="$PKG_DIR/.headers"
FFMPEG_SRC_DIR="$SCRIPT_DIR/ffmpeg-$FFMPEG_VERSION"
BUILD_SCRIPT="$SCRIPT_DIR/build-ffmpeg-tvos.sh"

LIBS=(
  libavcodec
  libavdevice
  libavfilter
  libavformat
  libavutil
  libswresample
  libswscale
)

patch_ffmpeg_securetransport_check() {
  local configure_file="$FFMPEG_SRC_DIR/configure"

  if [[ ! -f "$configure_file" ]]; then
    echo "Warning: FFmpeg configure file not found at $configure_file"
    echo "Skipping configure patch."
    return
  fi

  if grep -q "SSLCreateContext SecItemImport" "$configure_file"; then
    echo "Applying tvOS SecureTransport configure patch..."
    perl -0pi -e 's/SSLCreateContext SecItemImport/SSLCreateContext/g' "$configure_file"
    echo "Patched: removed SecItemImport requirement for securetransport detection."
  else
    echo "SecureTransport configure patch already applied (or not needed)."
  fi
}

patch_ffmpeg_securetransport_source() {
  local tls_file="$FFMPEG_SRC_DIR/libavformat/tls_securetransport.c"

  if [[ ! -f "$tls_file" ]]; then
    echo "Warning: FFmpeg source file not found at $tls_file"
    echo "Skipping source patch."
    return
  fi

  if grep -q "FFMPEG_TVOS_SECURETRANSPORT_PATCH" "$tls_file"; then
    echo "SecureTransport source patch already applied."
    return
  fi

  echo "Applying tvOS SecureTransport source patch..."

  perl -0pi -e 's/#include <CoreFoundation\/CoreFoundation\.h>/#include <CoreFoundation\/CoreFoundation.h>\n#include <TargetConditionals.h>/' "$tls_file"

  perl -0pi -e 's/static int import_pem\(URLContext \*h, char \*path, CFArrayRef \*array\)\n\{/static int import_pem(URLContext *h, char *path, CFArrayRef *array)\n{\n#if TARGET_OS_TV\n    \/\/ FFMPEG_TVOS_SECURETRANSPORT_PATCH: tvOS SDK does not expose SecItemImport APIs.\n    av_log(h, AV_LOG_ERROR, "Custom CA\/client certificates are unsupported on tvOS SecureTransport\\n");\n    return AVERROR(ENOSYS);\n#else/' "$tls_file"

  perl -0pi -e 's/return ret;\n\}\n\nstatic int load_ca/return ret;\n#endif\n}\n\nstatic int load_ca/' "$tls_file"

  perl -0pi -e 's/static int load_cert\(URLContext \*h\)\n\{/static int load_cert(URLContext *h)\n{\n#if TARGET_OS_TV\n    \/\/ FFMPEG_TVOS_SECURETRANSPORT_PATCH: client certificate import is unavailable on tvOS.\n    av_log(h, AV_LOG_ERROR, "Client certificates are unsupported on tvOS SecureTransport\\n");\n    return AVERROR(ENOSYS);\n#else/' "$tls_file"

  perl -0pi -e 's/if \(id\)\n        CFRelease\(id\);\n    return ret;\n\}/if (id)\n        CFRelease(id);\n    return ret;\n#endif\n}/' "$tls_file"

  echo "Patched: tvOS-specific SecureTransport fallback in tls_securetransport.c"
}

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

if [[ "$REBUILD_FFMPEG" -eq 1 ]]; then
  ensure_ffmpeg_source_tree

  export FFMPEG_VERSION
  export SOURCE="ffmpeg-$FFMPEG_VERSION"

  echo "Rebuilding with FFmpeg version: $FFMPEG_VERSION"
  patch_ffmpeg_securetransport_check
  patch_ffmpeg_securetransport_source

  if [[ ! -x "$BUILD_SCRIPT" ]]; then
    echo "Error: Build script not found or not executable: $BUILD_SCRIPT"
    exit 1
  fi

  echo "Rebuilding FFmpeg tvOS libraries..."
  "$BUILD_SCRIPT"
fi

# -------- validation --------
echo "Validating build outputs..."

for d in "$DEVICE_DIR" "$SIM_DIR"; do
  if [[ ! -d "$d/lib" ]]; then
    echo "Error: Missing directory $d/lib"
    echo "Run ./build-ffmpeg-tvos.sh lipo first (or use --rebuild)."
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
mkdir -p "$PKG_DIR/Sources/FFmpegTVOSSupport"
mkdir -p "$OUT_XCF_DIR"
mkdir -p "$TMP_HEADERS_DIR"

echo "Package directory: $PKG_DIR"

prune_unsupported_headers() {
  local module_name="$1"
  local module_headers_dir="$2"

  case "$module_name" in
    libavcodec)
      rm -f "$module_headers_dir/xvmc.h" \
            "$module_headers_dir/vdpau.h" \
            "$module_headers_dir/qsv.h" \
            "$module_headers_dir/dxva2.h" \
            "$module_headers_dir/d3d11va.h" \
            "$module_headers_dir/vaapi.h" \
            "$module_headers_dir/vda.h" \
            "$module_headers_dir/jni.h"
      ;;
    libavutil)
      rm -f "$module_headers_dir/hwcontext_vulkan.h" \
            "$module_headers_dir/hwcontext_vdpau.h" \
            "$module_headers_dir/hwcontext_vaapi.h" \
            "$module_headers_dir/hwcontext_qsv.h" \
            "$module_headers_dir/hwcontext_opencl.h" \
            "$module_headers_dir/hwcontext_dxva2.h" \
            "$module_headers_dir/hwcontext_d3d11va.h" \
            "$module_headers_dir/hwcontext_cuda.h"
      ;;
  esac
}

write_module_map() {
  local module_name="$1"
  local modulemap_path="$2"

  cat > "$modulemap_path" <<MAP
module ${module_name} {
    umbrella "."
    export *
}
MAP
}

# -------- create XCFrameworks --------
echo "Creating XCFrameworks..."

for name in "${LIBS[@]}"; do
  DEV_LIB="$DEVICE_DIR/lib/${name}.a"
  SIM_LIB="$SIM_DIR/lib/${name}.a"
  SRC_HEADERS="$HEADERS_DIR/$name"
  LIB_HEADERS_ROOT="$TMP_HEADERS_DIR/$name"
  LIB_HEADERS_DIR="$LIB_HEADERS_ROOT/$name"

  if [[ ! -f "$DEV_LIB" ]]; then
    echo "Error: Missing $DEV_LIB"
    exit 1
  fi

  if [[ ! -f "$SIM_LIB" ]]; then
    echo "Error: Missing $SIM_LIB"
    exit 1
  fi

  if [[ ! -d "$SRC_HEADERS" ]]; then
    echo "Error: Missing headers directory $SRC_HEADERS"
    exit 1
  fi

  echo "Processing $name"

  rm -rf "$LIB_HEADERS_ROOT"
  mkdir -p "$LIB_HEADERS_DIR"
  cp -R "$SRC_HEADERS/." "$LIB_HEADERS_DIR/"

  prune_unsupported_headers "$name" "$LIB_HEADERS_DIR"
  write_module_map "$name" "$LIB_HEADERS_DIR/module.modulemap"

  xcodebuild -create-xcframework \
    -library "$DEV_LIB" -headers "$LIB_HEADERS_ROOT" \
    -library "$SIM_LIB" -headers "$LIB_HEADERS_ROOT" \
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
        .library(name: "FFmpegTVOSSupport", targets: ["FFmpegTVOSSupport"]),
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
            name: "FFmpegTVOSSupport",
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

cat > "$PKG_DIR/Sources/FFmpegTVOSSupport/FFmpegSupport.swift" <<'SWIFT'
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
echo "3. Link FFmpegTVOSSupport to your tvOS target"
echo "--------------------------------------------"
