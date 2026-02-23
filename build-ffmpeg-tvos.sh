#!/bin/sh

# directories
SOURCE="${SOURCE:-ffmpeg-${FFMPEG_VERSION:-3.4}}"
FAT="FFmpeg-tvOS"

SCRATCH="scratch-tvos"
# must be an absolute path
THIN=`pwd`/"thin-tvos"

# absolute path to x264 library
#X264=`pwd`/../x264-ios/x264-iOS

#FDK_AAC=`pwd`/fdk-aac/fdk-aac-ios

CONFIGURE_FLAGS="--enable-cross-compile --disable-debug --disable-programs \
                 --disable-doc --enable-pic --disable-indev=avfoundation \
                 --disable-asm"

if [ "$X264" ]
then
	CONFIGURE_FLAGS="$CONFIGURE_FLAGS --enable-gpl --enable-libx264"
fi

if [ "$FDK_AAC" ]
then
	CONFIGURE_FLAGS="$CONFIGURE_FLAGS --enable-libfdk-aac"
fi

# avresample
#CONFIGURE_FLAGS="$CONFIGURE_FLAGS --enable-avresample"

ARCHS="arm64 arm64-sim"

COMPILE="y"
LIPO="y"

DEPLOYMENT_TARGET="9.0"

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
	if [ ! `which yasm` ]
	then
		echo 'Yasm not found'
		if [ ! `which brew` ]
		then
			echo 'Homebrew not found. Trying to install...'
                        ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)" \
				|| exit 1
		fi
		echo 'Trying to install Yasm...'
		brew install yasm || exit 1
	fi
	if [ ! `which gas-preprocessor.pl` ]
	then
		echo 'gas-preprocessor.pl not found. Trying to install...'
		(curl -L https://github.com/libav/gas-preprocessor/raw/master/gas-preprocessor.pl \
			-o $HOME/bin/gas-preprocessor.pl \
			&& chmod +x $HOME/bin/gas-preprocessor.pl) \
			|| exit 1
	fi

	if [ ! -r $SOURCE ]
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

		EXPORT=
		if [ "$ARCH" = "arm64-sim" ]
		then
    			# Simulator (Apple Silicon)
    			PLATFORM="AppleTVSimulator"
    			CFLAGS="-arch arm64 -mtvos-simulator-version-min=$DEPLOYMENT_TARGET"
    			ARCH="arm64"
		else
    			# Device
    			PLATFORM="AppleTVOS"
    			CFLAGS="-arch $ARCH -mtvos-version-min=$DEPLOYMENT_TARGET -fembed-bitcode"
    			EXPORT="GASPP_FIX_XCODE5=1"
		fi

		XCRUN_SDK=`echo $PLATFORM | tr '[:upper:]' '[:lower:]'`
		CC="xcrun -sdk $XCRUN_SDK clang"
		AR="xcrun -sdk $XCRUN_SDK ar"
		CXXFLAGS="$CFLAGS"
		LDFLAGS="$CFLAGS"
		if [ "$X264" ]
		then
			CFLAGS="$CFLAGS -I$X264/include"
			LDFLAGS="$LDFLAGS -L$X264/lib"
		fi
		if [ "$FDK_AAC" ]
		then
			CFLAGS="$CFLAGS -I$FDK_AAC/include"
			LDFLAGS="$LDFLAGS -L$FDK_AAC/lib"
		fi

		TMPDIR=${TMPDIR/%\/} $CWD/$SOURCE/configure \
		    --target-os=darwin \
		    --arch=$ARCH \
		    --cc="$CC" \
		    --ar="$AR" \
		    $CONFIGURE_FLAGS \
		    --extra-cflags="$CFLAGS" \
		    --extra-ldflags="$LDFLAGS" \
		    --prefix="$THIN/`basename $PWD`" \
		|| exit 1

		xcrun -sdk $XCRUN_SDK make -j3 install $EXPORT || exit 1
		cd $CWD
	done
fi

if [ "$LIPO" ]
then
    echo "creating device + simulator outputs (no mixed lipo)..."

    DEVICE_OUT="FFmpeg-tvOS"
    SIM_OUT="FFmpeg-tvOS-sim"

    mkdir -p "$DEVICE_OUT/lib" "$SIM_OUT/lib"

    # pick a reference include dir from device build
    set - $ARCHS
    CWD=`pwd`
    FIRST_ARCH="$1"

    # copy headers (same headers for device + sim)
    cp -rf "$THIN/$FIRST_ARCH/include" "$DEVICE_OUT" || exit 1
    cp -rf "$THIN/$FIRST_ARCH/include" "$SIM_OUT" || exit 1

    # device libs: copy as-is (arm64 device)
    for LIB in "$THIN/arm64/lib/"*.a
    do
        cp -f "$LIB" "$DEVICE_OUT/lib/" || exit 1
    done

    # simulator libs: use whichever simulator slices are available.
    # Newer Apple Silicon-only environments often build arm64-sim only.
    REF_SIM_ARCH=
    if [ -d "$THIN/arm64-sim/lib" ]; then
        REF_SIM_ARCH="arm64-sim"
    elif [ -d "$THIN/x86_64/lib" ]; then
        REF_SIM_ARCH="x86_64"
    else
        echo "No simulator libraries were produced in $THIN (expected arm64-sim and/or x86_64)."
        exit 1
    fi

    for LIB in "$THIN/$REF_SIM_ARCH/lib/"*.a
    do
        NAME=`basename "$LIB"`
        ARM64_SIM_LIB="$THIN/arm64-sim/lib/$NAME"
        X86_SIM_LIB="$THIN/x86_64/lib/$NAME"

        if [ -f "$ARM64_SIM_LIB" ] && [ -f "$X86_SIM_LIB" ]; then
            echo lipo -create "$ARM64_SIM_LIB" "$X86_SIM_LIB" -output "$SIM_OUT/lib/$NAME" 1>&2
            lipo -create "$ARM64_SIM_LIB" "$X86_SIM_LIB" -output "$SIM_OUT/lib/$NAME" || exit 1
        elif [ -f "$ARM64_SIM_LIB" ]; then
            cp -f "$ARM64_SIM_LIB" "$SIM_OUT/lib/$NAME" || exit 1
        elif [ -f "$X86_SIM_LIB" ]; then
            cp -f "$X86_SIM_LIB" "$SIM_OUT/lib/$NAME" || exit 1
        else
            echo "Missing simulator library slices for $NAME"
            exit 1
        fi
    done
fi

echo "Done"
echo "Device libs: $DEVICE_OUT"
echo "Simulator libs: $SIM_OUT"
