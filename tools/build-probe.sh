#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
probe_bundle="build/AudioMixProbe.app/Contents"
mkdir -p "$probe_bundle/MacOS" build/module-cache
cp tools/Probe-Info.plist "$probe_bundle/Info.plist"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
  -fmodules-cache-path="$PWD/build/module-cache" \
  -framework Foundation -framework IOBluetooth \
  -Wl,-sectcreate,__TEXT,__info_plist,tools/Probe-Info.plist \
  tools/bluetooth-probe.m -o "$probe_bundle/MacOS/AudioMixProbe"
codesign --force --sign - "build/AudioMixProbe.app"
echo "Built build/AudioMixProbe.app"
