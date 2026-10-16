#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
wired_bundle="$PWD/build/AudioMixWired.app/Contents"
mkdir -p "$wired_bundle/MacOS" build/wired-objects
cp tools/WiredTest-Info.plist "$wired_bundle/Info.plist"
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -ISources/Wired -c Sources/Wired/AudioPipe.c -o build/wired-objects/AudioPipe.o
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -ISources/Wired -c Sources/Wired/SamplePCM.c -o build/wired-objects/SamplePCM.o
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -ISources/Wired -c Sources/Wired/MacVolumeRender.c -o build/wired-objects/MacVolumeRender.o
xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -ISources/Wired Sources/Wired/main.m Sources/Wired/WiredCapture.m Sources/Wired/MacAudio.m Sources/Wired/DeviceVolumePanel.m \
  build/wired-objects/AudioPipe.o build/wired-objects/SamplePCM.o build/wired-objects/MacVolumeRender.o \
  -framework AppKit -framework Foundation -framework AVFoundation -framework CoreMedia \
  -framework CoreMediaIO -framework AudioUnit -framework AudioToolbox -framework CoreAudio \
  -Wl,-sectcreate,__TEXT,__info_plist,tools/WiredTest-Info.plist \
  -o "$wired_bundle/MacOS/AudioMixWired"
if [ -f build/coredevice-target/debug/audiomix-coredevice-probe ]; then
  cp build/coredevice-target/debug/audiomix-coredevice-probe "$wired_bundle/MacOS/AudioMixCoreDeviceProbe"
  codesign --force --sign "${AUDIOMIX_SIGN_IDENTITY:--}" "$wired_bundle/MacOS/AudioMixCoreDeviceProbe"
  mkdir -p "$wired_bundle/Resources"
  cp research/idevice/LICENSE.txt "$wired_bundle/Resources/idevice-MIT.txt"
fi
codesign --force --sign "${AUDIOMIX_SIGN_IDENTITY:--}" "$PWD/build/AudioMixWired.app"
codesign --verify --deep --strict "$PWD/build/AudioMixWired.app"
echo "Built $PWD/build/AudioMixWired.app"
