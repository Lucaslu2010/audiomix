#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/wired-tests
xcrun clang -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  -fno-omit-frame-pointer -ISources/Wired Sources/Wired/AudioPipe.c tests/wired-tests.c \
  -framework AudioUnit -framework AudioToolbox -framework CoreAudio -framework CoreFoundation \
  -o build/wired-tests/wired-tests
build/wired-tests/wired-tests
xcrun clang -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  -fno-omit-frame-pointer -ISources/Wired Sources/Wired/AudioPipe.c Sources/Wired/SamplePCM.c tests/sample-pcm-tests.c \
  -framework CoreMedia -framework CoreFoundation -framework AudioUnit -framework AudioToolbox -framework CoreAudio \
  -o build/wired-tests/sample-pcm-tests
build/wired-tests/sample-pcm-tests
xcrun clang -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  -fno-omit-frame-pointer -ISources/Wired Sources/Wired/AudioPipe.c Sources/Wired/MacVolumeRender.c tests/mac-volume-tests.c \
  -framework CoreFoundation -framework AudioUnit -framework AudioToolbox -framework CoreAudio \
  -o build/wired-tests/mac-volume-tests
build/wired-tests/mac-volume-tests
