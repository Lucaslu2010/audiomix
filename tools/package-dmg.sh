#!/bin/sh
# Package an existing app without touching a running development bundle.
# This script deliberately makes an ad-hoc-signed, non-notarized test DMG.
set -eu
cd "$(dirname "$0")/.."
package_app="${1:-$PWD/build/AudioMixWired.app}"
package_output="${2:-$PWD/build/releases}"
if [ "$#" -gt 2 ] || [ ! -f "$package_app/Contents/Info.plist" ]; then
  echo 'Usage: sh tools/package-dmg.sh [path/to/AudioMixWired.app] [output-directory]' >&2
  exit 2
fi
package_app=$(cd "$(dirname "$package_app")" && pwd)/$(basename "$package_app")
mkdir -p "$package_output"
package_output=$(cd "$package_output" && pwd)
package_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$package_app/Contents/Info.plist")
package_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$package_app/Contents/Info.plist")
package_arch=$(lipo -archs "$package_app/Contents/MacOS/$package_executable" | tr ' ' '-')
case "$package_version$package_arch" in *[!A-Za-z0-9._-]*) echo 'Invalid release version or architecture' >&2; exit 2;; esac
package_name="AudioMix-$package_version-macOS-$package_arch-adhoc"
package_dmg="$package_output/$package_name.dmg"
if [ -e "$package_dmg" ]; then
  echo "Refusing to overwrite an existing image: $package_dmg" >&2
  exit 1
fi
package_stage=$(mktemp -d "$package_output/.dmg-stage.XXXXXX")
package_stage_app="$package_stage/$(basename "$package_app")"
ditto "$package_app" "$package_stage_app"
if [ -f "$package_stage_app/Contents/MacOS/AudioMixCoreDeviceProbe" ]; then
  python3 tools/collect-probe-notices.py "$package_stage_app/Contents/Resources/Third-Party-Notices.txt"
fi
for package_binary in "$package_stage_app"/Contents/MacOS/*; do
  [ -f "$package_binary" ] && [ -x "$package_binary" ] || continue
  [ "$(basename "$package_binary")" != "$package_executable" ] || continue
  codesign --force --sign - "$package_binary"
done
codesign --force --sign - "$package_stage_app"
codesign --verify --deep --strict "$package_stage_app"
ln -s /Applications "$package_stage/Applications"
cat > "$package_stage/Read Me.txt" <<'TEXT'
AudioMix 0.7 — preview build

INSTALL
Drag AudioMixWired.app to Applications, eject this disk image, then launch the app.

QUICK START
Connect and unlock your iPad/iPhone with a data-capable USB cable and trust the Mac.
Refresh, choose the input and your preferred output, then Start audio.
Open Device volumes (Command-D) for independent device volume and mute.
Enable This Mac in that panel to control Mac apps separately from USB audio.
Allow microphone/camera-class capture and system audio access when requested.

SIGNING
The app and disk image are ad-hoc signed. They are not Developer ID signed or
notarized. An ad-hoc signature does not establish a trusted publisher identity;
macOS may block a downloaded copy under its normal security checks.

STATUS
This is an early prototype. USB + Mac playback through AirPods has been tested.
End-to-end gaming latency is unmeasured; AirPods add their own output buffering.
EQ, Wi-Fi audio and an iPad-to-Mac Bluetooth receiver are not available.

PRIVACY
Audio is processed locally for playback, not recorded to disk or uploaded.
Optional USB capabilities reads development-device information and starts no media.
Third-party notices for that helper are inside the app's Contents/Resources folder.
TEXT
cp README.md "$package_stage/README.md"
echo "Prepared signed app: $package_stage_app"
echo "Staging folder: $package_stage"
if ! hdiutil create -volname "AudioMix $package_version" -srcfolder "$package_stage" -fs HFS+ -format UDZO "$package_dmg"; then
  # Some restricted build environments cannot configure a temporary disk device.
  # The HFS+ mastering path creates a file-backed image without mounting it.
  echo 'Direct image creation unavailable; using HFS+ mastering and UDZO conversion.' >&2
  if [ -e "$package_dmg" ]; then
    mv "$package_dmg" "$package_stage-failed-create.dmg"
  fi
  package_hybrid="$package_stage-hfs.dmg"
  hdiutil makehybrid -hfs -hfs-volume-name "AudioMix $package_version" -o "$package_hybrid" "$package_stage"
  python3 tools/clean-mastered-image.py "$package_hybrid" "$(basename "$package_app")"
  hdiutil convert "$package_hybrid" -format UDZO -o "$package_dmg"
fi
codesign --sign - --identifier "local.audiomix.diskimage.$package_version.$package_arch" "$package_dmg"
codesign --verify --strict --verbose=2 "$package_dmg"
hdiutil verify "$package_dmg"
(cd "$package_output" && shasum -a 256 "$package_name.dmg" > "$package_name.dmg.sha256")
codesign -dvv "$package_dmg" 2> "$package_output/$package_name-signature.txt"
echo "Built ad-hoc-signed image: $package_dmg"
echo "Checksum: $package_dmg.sha256"
echo "Staging folder retained for inspection: $package_stage"
