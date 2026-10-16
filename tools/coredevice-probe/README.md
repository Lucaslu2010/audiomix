# AudioMix CoreDevice capability probe

This read-only tool checks whether a selected device exposes the media service
used by the Device Hub protocol. It is not a Wi-Fi audio receiver. It has no
pair/unpair, media-start/stop, developer-image installation, or remote-control
command.

Build from the AudioMix root with `sh tools/build-coredevice-probe.sh`. The script
checks out the reviewed MIT idevice revision if absent, builds with a project-local
Cargo cache and locks dependencies. Use `--offline` once dependencies are cached.

```sh
build/coredevice-target/debug/audiomix-coredevice-probe --list
build/coredevice-target/debug/audiomix-coredevice-probe --usb 0
build/coredevice-target/debug/audiomix-coredevice-probe --rsd DEVICE_TUNNEL_IP RSD_PORT
```

USB indices refer to the current USB-only inventory. The probe uses the local
Apple usbmuxd socket and existing host trust; it never creates new pairing records
or falls back to a wireless device. The RSD form requires the exact address/port
of an existing trusted development tunnel. It does not discover or scan ports.

Each invocation has a 15-second total timeout. A successful process exit means
the diagnostic report was produced, not that audio works. Check
`capability_query_error`, `display_service_advertised`, and the media support
report. `media_started` and `audio_reception_verified` remain false. Reports omit
response strings/blobs and never save pairing credentials.

Build the probe first, then rebuild `AudioMixWired.app` to bundle it. The native
**USB capabilities** button runs inventory and checks capabilities if exactly one
USB iOS device is present. Capture cannot start during the query. The native
GUI is needed in environments where the terminal sandbox blocks the USB socket;
PermissionDenied from that sandbox is not evidence of macOS incompatibility.

Verified locally: build, three focused tests, native process startup and a
successful empty USB inventory on macOS 26.1 / SDK 26.2. No connected-device media
capabilities or audio reception have been verified. See
[the investigation](../../docs/wired-and-wifi.md).

Dependency source: [jkcoxson/idevice](https://github.com/jkcoxson/idevice), revision
`3854a5df4a5a6dee71ffce4d8befc2ea356a8065`. Its MIT license is at
`research/idevice/LICENSE.txt` and copied into the native app when bundled. The
research checkout is separate from AudioMix's own source and remains unmodified.
