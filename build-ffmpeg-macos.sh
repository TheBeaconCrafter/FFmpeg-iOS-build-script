#!/bin/sh

# directories
SOURCE="${SOURCE:-ffmpeg-${FFMPEG_VERSION:-3.4}}"
FAT="FFmpeg-macOS"

SCRATCH="scratch-macos"
# must be an absolute path
THIN=`pwd`/"thin-macos"

CONFIGURE_FLAGS="--enable-cross-compile --disable-debug --disable-programs \
                 --disable-doc --enable-pic --disable-indev=avfoundation \
                 --disable-asm"

ARCHS="arm64 x86_64"

COMPILE="y"
LIPO="y"

DEPLOYMENT_TARGET="11.0"

if [ "$*" ]
then
	if [ "$*" = "lipo" ]
	then
		# skip compile
		COMPILE=
	else
		ARCHS="$*"
		if [ $# -eq 1 ]
		then
			# skip lipo
			LIPO=
		fi
	fi
fi

if [ "$COMPILE" ]
then
	if [ ! -r "$SOURCE" ]
	then
		echo 'FFmpeg source not found. Trying to download...'
		curl -L https://ffmpeg.org/releases/$SOURCE.tar.bz2 | tar xj \
			|| exit 1
	fi

	CWD=`pwd`
	for ARCH in $ARCHS
	do
		echo "building $ARCH..."
		mkdir -p "$SCRATCH/$ARCH"
		cd "$SCRATCH/$ARCH"
		ln -snf "$CWD/$SOURCE" src

		PLATFORM="MacOSX"
		CFLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET"
		XCRUN_SDK=`echo $PLATFORM | tr '[:upper:]' '[:lower:]'`
		CC="xcrun -sdk $XCRUN_SDK clang"
		AR="xcrun -sdk $XCRUN_SDK ar"
		LDFLAGS="$CFLAGS"

		TMPDIR=${TMPDIR/%\/} $CWD/$SOURCE/configure \
		    --target-os=darwin \
		    --arch=$ARCH \
		    --cc="$CC" \
		    --ar="$AR" \
		    $CONFIGURE_FLAGS \
		    --extra-cflags="$CFLAGS" \
		    --extra-ldflags="$LDFLAGS" \
		    --prefix="$THIN/$ARCH" \
		|| exit 1

		xcrun -sdk $XCRUN_SDK make -j3 install || exit 1
		cd $CWD
	done
fi

if [ "$LIPO" ]
then
	echo "creating universal macOS output..."
	mkdir -p "$FAT/lib"

	set - $ARCHS
	FIRST_ARCH="$1"

	cp -rf "$THIN/$FIRST_ARCH/include" "$FAT" || exit 1

	for LIB in "$THIN/$FIRST_ARCH/lib/"*.a
	do
		NAME=`basename "$LIB"`
		ARM64_LIB="$THIN/arm64/lib/$NAME"
		X86_LIB="$THIN/x86_64/lib/$NAME"

		if [ -f "$ARM64_LIB" ] && [ -f "$X86_LIB" ]; then
			echo lipo -create "$ARM64_LIB" "$X86_LIB" -output "$FAT/lib/$NAME" 1>&2
			lipo -create "$ARM64_LIB" "$X86_LIB" -output "$FAT/lib/$NAME" || exit 1
		elif [ -f "$ARM64_LIB" ]; then
			cp -f "$ARM64_LIB" "$FAT/lib/$NAME" || exit 1
		elif [ -f "$X86_LIB" ]; then
			cp -f "$X86_LIB" "$FAT/lib/$NAME" || exit 1
		else
			echo "Missing macOS library slices for $NAME"
			exit 1
		fi
	done
fi

echo "Done"
echo "macOS libs: $FAT"
