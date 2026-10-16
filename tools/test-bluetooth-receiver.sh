#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/receiver-tests
xcrun clang -fobjc-arc -Wall -Wextra -Werror -ISources \
  Sources/Service.m tests/service-tests.m -framework Foundation -framework IOBluetooth \
  -o build/receiver-tests/service-tests
build/receiver-tests/service-tests
xcrun clang -O1 -g -fsanitize=address -Wno-ignored-attributes -DSBC_HIGH_PRECISION \
  -include Sources/SBCCompatibility.h -dynamiclib \
  vendor/libsbc/sbc.c vendor/libsbc/sbc_primitives.c \
  -install_name @rpath/libsbc-test.dylib -o build/receiver-tests/libsbc-test.dylib
xcrun clang -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  -fno-omit-frame-pointer -Ivendor/libsbc -ISources \
  Sources/AVDTP.c Sources/Media.c tests/receiver-tests.c \
  -Lbuild/receiver-tests -lsbc-test \
  -o build/receiver-tests/receiver-tests
build/receiver-tests/receiver-tests
xcrun clang -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  -fno-omit-frame-pointer -ISources Sources/AVDTP.c Sources/Initiator.c tests/initiator-tests.c \
  -o build/receiver-tests/initiator-tests
build/receiver-tests/initiator-tests
xcrun clang -fobjc-arc -fblocks -O1 -g -Wall -Wextra -Werror -ISources -Ivendor/libsbc \
  -Dmain=am_test_application_entry -c Sources/main.m -o build/receiver-tests/app-delegate.o
xcrun clang -fobjc-arc -fblocks -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
  -ISources -Ivendor/libsbc tests/main-thread-tests.m build/receiver-tests/app-delegate.o \
  Sources/Receiver.m Sources/SourceInitiator.m Sources/Service.m \
  Sources/AVDTP.c Sources/Initiator.c Sources/Media.c Sources/AudioOutput.c \
  -framework Foundation -framework AppKit -framework CoreBluetooth -framework IOBluetooth \
  -framework AudioToolbox -framework CoreAudio -Lbuild/receiver-tests -lsbc-test \
  -o build/receiver-tests/main-thread-tests
build/receiver-tests/main-thread-tests
