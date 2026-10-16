# USB and Wi-Fi investigation

Last checked: 2026-10-16. The user verified simultaneous USB iPad and Mac playback
through AirPods. Independent source volumes are implemented in 0.7. Wireless
reception and game-to-ear delay remain unverified.

## Target architecture

Prefer a verified USB playback source for the selected iPad. Offer an explicit
Wi-Fi alternative for that same source. Both routes should produce timestamped
PCM for one source gain/EQ stage, a mixer with separately captured Mac music,
master EQ, and a user-selected Core Audio output. Do not mix both copies of the
same iPad audio. Change routes only after the replacement actually delivers
usable playback audio; flush old samples and use a short fade. Detecting a cable
or opening a session alone must not mark a route ready.

The current test app sorts confirmed USB transport first. It does not implement
Wi-Fi capture, automatic failover or EQ yet. Version 0.7 adds optional Mac
process-audio gain and independent connected-input volumes; see
[device volume controls](device-volumes.md).

## Wired test implemented

`build/AudioMixWired.app` is an independent macOS test app using public
AVFoundation, CoreMediaIO and Core Audio APIs. Build and check it with:

```sh
sh tools/build-wired-test.sh
sh tools/test-wired.sh
```

Connect and unlock the iPad/iPhone with a data-capable USB cable and accept Trust
This Computer. In the test app, Refresh, explicitly choose the device and output,
then Start audio. macOS may request microphone access and, for a screen/muxed
capture device, camera-class access. No Bluetooth receiver is started.

The default capture session adds only an audio data output. The separate
compatibility option activates a video output and discards its samples: it has
no preview or recording, but the underlying transport may still carry video.
This option is off by default and is not enabled automatically on failure.

Apple also documents enabling an iOS/iPadOS device in Audio MIDI Setup to make
its audio available to Mac apps. Enable the intended device there, then refresh
the test app. Test this separately from screen/muxed capture; older OBS issue
reports describe conflicts when using both routes simultaneously.

An iPhone-named input can be a Continuity physical microphone. A model name is
not proof of USB transport or game playback. Version 0.2 hides unverified,
audio-only iOS inputs behind Show other audio inputs, labels their uncertainty,
and logs device type, model, transport and media flags. It never automatically
opens a microphone as a fallback. An unknown-transport iOS muxed device remains
visible as an explicitly unverified screen/audio candidate.

The output uses AUHAL bound to the selected Core Audio device. Capture delivers
PCM to a bounded, single-producer/single-consumer float ring. The output render
callback allocates no memory and takes no locks. Audio delivery has an interactive
QoS queue; the hardware callback provides the output scheduling. No global audio
device sample rate, buffer size, default input or default output is changed.

Version 0.6 selects outputs by persistent Core Audio UID and resolves the current
device ID when the first captured buffer arrives (or when Test output starts).
A missing explicit output fails instead of falling back to the system default;
Refresh retains it as an unavailable selection. Setup validates a live device
with output streams and logs the failing property/initialization step, resolved
device name/ID, hardware format, nominal rate and maximum render slice.
The reported `-10851` is `kAudioUnitErr_InvalidPropertyValue`. The historical
0.5 log cannot identify its failing call: speakers worked, then selecting
“DICH-9 重型头盔” failed twice. That output was absent during investigation.
The instrumented speaker test rendered 48,640 frames at 48 kHz without a callback
error. This does not verify the missing headset or prove the historical cause.
After the UID-selection change, the one-second speaker test rendered 48,128
frames. A live iPad session then captured 1,654,784 PCM frames and rendered
1,648,128 frames with zero invalid buffers, zero PCM-copy fallbacks and zero
output callback errors. The observed input peak remained silent; audible game
playback is still unverified. Log export stopped responding during this session;
Escape and Quit did not close it, and the terminal sandbox denied termination.
Only AudioMix Wired Test was then force-quit through Activity Monitor and
relaunched successfully, idle. These figures were observed in the app UI, not a completed log
export. No Bluetooth output was available for the 0.6 retest.

Version 0.5 offers 5/10/20/40/80 ms queue caps, defaulting to 40 ms. The cap limits
queued frames and their age since receipt on the Mac; it is not a measured
game-to-ear latency or a target startup delay. Expired frames are discarded on
render, so an output stall does not replay an old tail. If capture continues but
the output stops rendering for over one second, capture stops with an error.
There is no adaptive clock correction or network jitter buffer yet. AirPods
output adds its own codec/radio/device buffering regardless of input transport.

## What the Xcode 27 observation likely was

Apple introduced **Device Hub** with Xcode 27. It provides a live, interactive
view of physical devices as well as simulators. Its documentation specifies
iOS/iPadOS 27 or later for its new wireless pairing flow, same-network discovery,
and potentially Developer Mode. The exact feature the user saw is not confirmed.

There is an MIT-licensed open-source implementation,
[`JaviSoto/device-hub-ios`](https://github.com/JaviSoto/device-hub-ios), built on
[`jkcoxson/idevice`](https://github.com/jkcoxson/idevice). This establishes that
the protocol is being implemented outside Apple's app; it does not establish
working audio-only reception or FPS-suitable latency.

Source inspected at idevice revision
`3854a5df4a5a6dee71ffce4d8befc2ea356a8065` exposes the private
`com.apple.coredevice.displayservice` with media-support queries, audio/video
start parameters and separate CoreDeviceSystemAudio negotiation. The iOS port's
protocol document calls its audio setup an **inert audio prerequisite** for video;
its advertised media pipeline is HEVC. No working audio decoder, negotiated
audio-only session or audio latency measurement was verified in this research.
Do not count that prerequisite as received audio.

A direct Device Hub-compatible experiment would first query system-audio
capabilities on an explicitly selected, paired development device, then negotiate
audio alone and inspect the actual codec/packet timing before adding playback.
This uses undocumented services and may require prepared developer images and
protocol changes across OS updates. Never stop another host's media session or
assume that its generic stop-all command belongs to AudioMix.

## Public API Wi-Fi route

There is a separate public path using a companion sender on the iPad and a Mac
receiver. Apple's iOS 27 ScreenCaptureKit sample supports user-consented
full-display capture with `SCContentSharingPicker` and declares the
`screen-capture` background mode. `SCStreamConfiguration.capturesAudio` enables
audio delivery. A prototype should attach an audio output, send PCM or a short
frame codec directly over the LAN, and omit video encoding/transmission. Whether
an audio-only configuration continues correctly while this particular game runs
is a real-device test requirement, not established by the generic sample.

For iOS/iPadOS 26, a ReplayKit broadcast upload extension is a possible older-OS
sender: handle app-audio sample buffers and discard video/microphone samples.
This is different from `RPScreenRecorder` recording only our own app. Apple now
marks the broadcast-extension APIs deprecated in its newer documentation; do not
assume identical behavior across 26 and 27. Voice chat, protected content and
games that suppress capture need separate checks.

iOS 27 also introduces MediaDevice/AVSystemRouting for a third-party output in
the system media picker, with real-time audio support and an audio server driver
plug-in requirement. This might eventually give a more natural “AudioMix Mac”
output selection. It requires the media-device extension entitlement in both
the extension and a dedicated container app. It is a further research route,
not an implemented virtual speaker or a guaranteed capture path for every game.

For a controllable LAN transport, use short packets, sequence numbers, capture
timestamps, session authentication, bounded reordering, loss concealment and
clock-drift correction. Avoid retransmitting audio past its playback deadline.
Start with PCM to separate capture delay from codec delay, then evaluate a
short-frame codec against Wi-Fi bandwidth/power. Audio priority can reduce local
scheduling delays; it cannot remove capture, network or AirPods buffering.
No numeric end-to-end latency promise follows from this design.

## macOS 26 protocol replication: source review and local build

The earlier iOS 27 SDK constraint applies to the **new public iPad companion
capture API**, not necessarily to a Mac implementation of the Device Hub
protocol. These are separate approaches.

Source checkouts inspected without changing either upstream project:

- Device Hub iOS: `b5994ff72d8c75d68370ae80aa3efaa4e590686d`.
- idevice: `3854a5df4a5a6dee71ffce4d8befc2ea356a8065`.

DeviceHubKit's package manifest explicitly lists `.macOS(.v26)` and `.iOS(.v27)`.
It requires Swift tools 6.4, so this declaration alone does not prove that the
whole app builds with our Xcode 26.3. The shipping UI and FFI packaging target
iOS and need a native Mac target.

The wireless path uses Bonjour discovery, authenticated pairing/Pair Verify,
a TLS-PSK CDTunnel, userspace TCP/IP, RSD and RemoteXPC. The reviewed app checks
target Developer Mode and an already-prepared personalized developer image.
It negotiates audio mode 6 and then video mode 5 under one session ID; the media
loop receives RTP HEVC and uses VideoToolbox. HID/orientation are additional
remote-control services that an audio receiver would not need.

A local wrapper with the remote-pairing, software-tunnel, display-stream and USB
features **compiled and executed on macOS 26.1 using SDK 26.2**. Its binary declares
macOS 14.0 minimum and links libSystem/libiconv. The transport uses Rust/network
code rather than the iOS 27 ScreenCaptureKit API. This establishes host build and
process-start compatibility, not a successful device session.

In the reviewed live path, `audio_udp` is retained as `_audio_udp` while the
receive loop processes video. There is no decoded system-audio playback path.
We still need to negotiate a real audio format, receive/depacketize/decode it,
and determine whether audio alone is accepted.

**A macOS 26 host implementation is technically plausible, with a local protocol
build as evidence.** Target iPad compatibility is unknown. A missing service on
iPadOS 26 cannot be supplied by changing only the Mac client. The upstream app
is verified against iOS/iPadOS 27 Beta 3, not our target game/device. Developer
readiness, actual audio reception and latency remain separate gates.

### Read-only capability probe

`tools/coredevice-probe` wraps the pinned MIT idevice library. It exposes inventory
and capability queries only, with no media-start, stop-all, HID, pairing/unpairing,
developer-image mounting or installation operation. Existing pairing material
stays in memory and is not printed or saved.

```sh
sh tools/build-coredevice-probe.sh
build/coredevice-target/debug/audiomix-coredevice-probe --list
build/coredevice-target/debug/audiomix-coredevice-probe --usb 0
```

`--usb INDEX` selects a USB-only inventory entry and queries OS version, remote
services and media support; it never falls back to Wi-Fi. `--rsd IP PORT` queries
an explicitly supplied, already-established trusted development tunnel. No port
scan occurs. Queries have a 15-second overall timeout and never mark audio as
verified. Capability reports omit response strings and data blobs.

The build needs Rust and registry dependencies. Cargo could not resolve registry
hosts inside the command sandbox. Public packages were fetched with curl into a
project-local cache and SHA-256 checked against the generated lockfile; building
with `sh tools/build-coredevice-probe.sh --offline` then succeeded. No global
Cargo configuration or user cache was modified.

If built before the wired app, the probe is bundled as a signed optional helper.
**USB capabilities** runs inventory in the native app and, only if exactly one
USB device is present, queries that device's capabilities. Capture is disabled
while querying. Multiple devices require an explicit CLI index. USB audio capture
does not depend on the helper or on a development pairing/image.

The ordinary terminal sandbox returned socket PermissionDenied/OS error 1 for
usbmuxd and hid Core Audio devices. These observations must not be mistaken for
missing hardware or macOS incompatibility; use the native GUI for live inventory.

## Local evidence and remaining gates

### PCM-buffer failure and live USB capture, 2026-10-16

The 0.3 screen/audio route opened `vide`, `soun`, `clcp` and `mobj` input ports
but stopped at its first retained-buffer-list access. In 0.4, logging showed
`kCMSampleBufferError_ArrayTooSmall` (-12737), with a required list size of
24 bytes. Its new bounded PCM-copy fallback succeeded. From 00:18:25 until
00:18:56, the app received 1,280 chunks / **1,310,720 PCM frames** and rendered
1,495,552 frames with output error 0. The user confirmed that the ending device
disconnect was an intentional iPad restart to enable Developer Mode for another
project, not an unexplained receiver disconnect.

The incoming format was 48,000 Hz, stereo, float32 interleaved PCM (flags 0x9),
1,024 frames / 8,192 bytes per chunk. A 1,024-frame chunk lasts 21.33 ms, so the
old 20 ms frame cap necessarily discarded part of full chunks. A 40 ms cap was
selected for the follow-up capture; it remains a cap rather than deliberate
startup buffering. Silent-fill counts include pauses and are not a standalone
dropout/quality measurement.

A standalone real-Core-Media reproduction established the original size bug:
the interleaved sample's one-buffer list succeeds with 24 bytes but returns
-12737 when passed the larger 40-byte, two-buffer allocation size. Planar stereo
requires 40 bytes. Version 0.5 passes the exact list size implied by the PCM
layout and channel count, retains the copy fallback, and defaults to 40 ms.
The new regression assertion failed before this fix and passed afterward.
ASan/UBSan Core Media tests also cover planar, fragmented and missing sample
data, empty buffers and offset ranges. Normal tests do not require an iPad.
The native 0.4 live log is saved at `build/AudioMix-USB-0.4.log`.
Version 0.5 was subsequently built, signed and opened at 00:32:24. The connected
iPad delivered the same 48 kHz stereo interleaved PCM; the direct retained-list
path succeeded with **copies 0, invalid 0 and output error 0**. Only two startup
chunks had arrived at the observed snapshot, with a silent last chunk, so this
does not verify sustained non-silent game playback. The initial output test
resolved the system default (reported device latency 7,680 frames at 48 kHz);
an explicit MacBook Air Speakers session was then started at 00:36:00.
That speaker session subsequently received **2,260 chunks / 2,314,240 frames**
and rendered 2,309,120 frames, with copy fallbacks 0, invalid 0, silent-fill 0
and output error 0. Its queue snapshot was 29.3 ms; 3,712 frames had been dropped,
including 1,024 expired startup frames. The last input peak was silent, so
audibility and game-to-ear latency still require an identifiable playing sound.

After the restart, 0.4 restarted capture at 00:23:52 and again received PCM at
00:23:57, with no reported output error. These observations verify PCM reception
and output callbacks, not audibility, non-silent game content or end-to-end delay.

### Target services before/after Developer Mode restart

The native read-only probe successfully traversed existing USB trust,
CoreDeviceProxy and RSD on the iPad reporting **26.3.1**, from the macOS 26.1
host. At 00:15:52, RSD protocol 7 exposed 58 services. At 00:22:49, after the
user's Developer Mode restart, the service count was 73. Neither list advertised
`com.apple.coredevice.displayservice`. No stream-start operation was attempted.
This establishes more than host compilation, but does not prove the service is
absent in every iPadOS 26 configuration. Personalized developer-image readiness
was not independently checked or changed by AudioMix.

### Earlier checks

- Installed Xcode: **26.3 (17C529)**; available iOS SDK: **26.2**. The new iOS 27
  public APIs cannot currently be compiled/tested with that SDK. No OS or Xcode
  upgrade, developer-image installation or device security change was performed.
- Wired version 0.1 GUI output test at 23:17:05–23:17:06 rendered **48,128 frames**,
  with output error 0. This proves the render path ran, not audibility or USB input.
- The only initial iOS input was named “… Microphone”; its transport/playback
  identity was unverified. It was not opened. Version 0.2 corrects its default
  classification and adds detailed discovery logging. Version 0.2 was rebuilt
  and opened successfully at 23:21:45; its default view showed **0 candidate
  USB inputs and 9 outputs**, with no capture running.
- `devicectl list devices --timeout 10` timed out; this did not establish a
  connected development device, OS version or developer readiness.
- ASan/UBSan tests cover PCM conversion, malformed buffers, bounded queues,
  gain/clipping, underruns, recovery after an output stall and concurrent
  producer/consumer ordering. Three probe tests cover explicit commands,
  omission of response strings/blobs and useful error categories. These
  tests do not establish wired or wireless iPad interoperability.
- Version 0.3 was opened at 23:55:25 with its 20 ms default cap, no capture
  running, and a responsive GUI. Native discovery completed with 0 candidate
  USB audio inputs and 9 outputs. At 23:56:21 its bundled protocol helper
  completed USB inventory with exit 0 and `usb_device_count: 0`. This verifies
  that the helper can run and reach Apple's local USB daemon outside the command
  sandbox on macOS 26.1. No remote capability query or media startup followed.

Next hardware gates: capture an identifiable sound from the target game over
USB, verify audibility/stereo, then compare a Wi-Fi sender with the same output.
Measure the entire game-to-ear path, plus the Mac receive-to-output portion,
under load and over long sessions. Record dropouts and queue growth, not just an
average delay. First compare with Mac wired/speaker output, then repeat with
AirPods to expose the additional output delay.

## Primary sources

- [Apple: Audio MIDI Setup with iOS/iPadOS devices](https://support.apple.com/en-au/guide/audio-midi-setup/ams59f301fda/mac)
- [OBS AVFoundation implementation](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-avcapture/OBSAVCapture.m) — inspected for capture approach; no OBS source copied into this app.
- [Apple: Get the most out of Device Hub, WWDC26](https://developer.apple.com/videos/play/wwdc2026/260/)
- [Apple: Device Hub device management and pairing](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub)
- [Device Hub iOS: protocol and security](https://github.com/JaviSoto/device-hub-ios/blob/main/Docs/ProtocolSecurity.md)
- [idevice display-service source at inspected revision](https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/idevice/src/services/core_device/display_stream/client.rs)
- [Apple: Capturing screen content on iOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)
- [Apple: ScreenCaptureKit audio configuration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)
- [Apple: ReplayKit broadcast sample handler](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler)
- [Apple: Media Device framework](https://developer.apple.com/documentation/mediadevice)
- [Apple: Routing and streaming media to remote devices](https://developer.apple.com/documentation/avsystemrouting/routing-and-streaming-media-to-remote-devices)
- [Apple: Media-device extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.media-device-extension)
