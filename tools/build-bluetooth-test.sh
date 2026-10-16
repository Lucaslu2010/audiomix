#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
receiver_bundle="$PWD/build/AudioMixBluetooth.app/Contents"
mkdir -p "$receiver_bundle/MacOS" "$receiver_bundle/Frameworks" "$receiver_bundle/Resources" build/receiver-objects build/module-cache
cp tools/BluetoothTest-Info.plist "$receiver_bundle/Info.plist"
cp vendor/libsbc/COPYING.LIB vendor/libsbc/UPSTREAM.md "$receiver_bundle/Resources/"
# Keep libsbc replaceable and ship its corresponding source/license in the repo.
xcrun clang -O2 -Wno-ignored-attributes -DSBC_HIGH_PRECISION -include Sources/SBCCompatibility.h \
  -dynamiclib -fvisibility=hidden -mmacosx-version-min=14.0 \
  vendor/libsbc/sbc.c vendor/libsbc/sbc_primitives.c \
  -install_name @rpath/libsbc.dylib -o "$receiver_bundle/Frameworks/libsbc.dylib"
for receiver_source in AVDTP Initiator Media AudioOutput; do
  xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
    -Ivendor/libsbc -ISources -c "Sources/$receiver_source.c" \
    -o "build/receiver-objects/$receiver_source.o"
done
xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -fmodules-cache-path="$PWD/build/module-cache" -Ivendor/libsbc -ISources \
  Sources/main.m Sources/Receiver.m Sources/SourceInitiator.m Sources/Service.m build/receiver-objects/AVDTP.o build/receiver-objects/Initiator.o \
  build/receiver-objects/Media.o build/receiver-objects/AudioOutput.o \
  -framework AppKit -framework Foundation -framework CoreBluetooth \
  -framework IOBluetooth -framework AudioToolbox -framework CoreAudio \
  -L"$receiver_bundle/Frameworks" -lsbc -Wl,-rpath,@executable_path/../Frameworks \
  -Wl,-sectcreate,__TEXT,__info_plist,tools/BluetoothTest-Info.plist \
  -o "$receiver_bundle/MacOS/AudioMixBluetooth"
codesign --force --sign - "$receiver_bundle/Frameworks/libsbc.dylib"
codesign --force --sign - "$PWD/build/AudioMixBluetooth.app"
echo "Built $PWD/build/AudioMixBluetooth.app"
