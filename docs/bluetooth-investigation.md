# Bluetooth receiver investigation, wired-first application

## Intended signal paths

Wireless candidates: iPad → native Bluetooth A2DP or software AirPlay receiver on Mac → volume/EQ/mix → AirPods.
Preferred when available: iPad → USB audio input on Mac → same processing → AirPods.
Mac music is a separate mixer input in both cases.

## Findings (2026-10-15)

The local environment is an Apple silicon Mac running macOS 26.1 with the macOS
SDK supplied by Xcode. The public IOBluetooth SDK includes SDP service publication
and incoming L2CAP notification APIs. These are primitives for investigating a
custom receiver, not an A2DP sink implementation.

- [Service publication](https://developer.apple.com/documentation/iobluetooth/iobluetoothsdpservicerecord)
- [Incoming L2CAP notifications](https://developer.apple.com/documentation/iobluetooth/iobluetoothl2capchannel/register(forchannelopennotifications:selector:withpsm:direction:))
- [SDP data encoding](https://developer.apple.com/documentation/iobluetooth/iobluetoothsdpdataelement)

Importantly, IOBluetoothSDPServiceRecord.h says macOS assigns an alternative L2CAP
PSM when the requested one is already in use. Merely publishing an Audio Sink
record therefore does not establish ownership of the standard AVDTP transport.
The probe checks the actual PSM and stops if it is not 0x0019. It must not claim
success after silently receiving an alternative PSM.

[Bluetooth assigned numbers](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/index-en.html)
identify Audio Sink as 0x110B, Advanced Audio Distribution as 0x110D, L2CAP as
0x0100, and AVDTP as 0x0019.

Apple documents enabling a connected iPad as a Mac audio input in
[Audio MIDI Setup](https://support.apple.com/en-au/guide/audio-midi-setup/ams59f301fda/mac).
This supplies a supported wired candidate; routing in the specific game and actual
latency still need testing.

Bluetooth receive support remains **unproven**, not established as impossible.

Local verification completed:

- The probe builds with ARC and warnings treated as errors using the installed SDK.
- Offline descriptor validation passes: Audio Sink UUID 0x110B and AVDTP PSM 0x0019
  decode through the SDK. The Info.plist passes `plutil -lint`.
- An invalid listen duration is rejected with exit code 2.
- A three-second live probe attempt returned nil from service publication and
  exited with code 1, before listener registration. The API supplied no detailed
  cause; Bluetooth access, permissions, sandbox context, or platform behavior remain
  possible explanations. No iPad stream, assigned live PSM, AirPods coexistence,
  or latency has been verified. Repeating the probe from the user's Terminal with
  Bluetooth access and the iPad present is the next diagnostic step.

The investigation should establish the following milestones separately:

1. Local publication at the correct PSM and listener registration.
2. iPad discovery, pairing, and an incoming connection delivered to our process.
3. AVDTP endpoint discovery, codec negotiation, and stream start.
4. Decoded PCM delivered to the mixer.
5. Simultaneous iPad reception and AirPods playback, including reconnect testing.
6. Measured game-event-to-ear delay and stability under game/network load.

The included probe covers the local setup for milestones 1–2 only. It logs packet
lengths without interpreting them and does not implement any stream endpoint.
A lack of callbacks is inconclusive: permission, discoverability, pairing, or
platform service ownership could be responsible. Do not treat a timeout as proof
that macOS cannot implement a sink.

## Current scope: software only

External receivers, dongles, and custom accessory firmware are out of scope.
The earlier hardware-based recommendations are withdrawn. Lack of a ready-made
native Bluetooth receiver is a development challenge, not a reason to change scope.
The older Bluetooth probe is retained. A new experimental A2DP/SBC receiver is
implemented in Sources/ and built as build/AudioMixBluetooth.app; live reception
and latency remain unverified. See the README for testing instructions.

## AirPlay to Mac: the iPad output option

Apple explicitly supports streaming iPad audio to a Mac. Enable AirPlay Receiver
under System Settings → General → AirDrop & Continuity (wording varies by macOS
version), then choose the Mac in the iPad audio app's AirPlay output picker.
Screen Mirroring is a separate entry point worth testing for game audio.
[Apple's instructions](https://support.apple.com/en-ie/guide/mac-help/mchld7e543a0/mac)

This is AirPlay over an IP network, not an incoming Bluetooth A2DP music stream.
Bluetooth can participate in discovery, while media uses a network connection.
Apple documents Bonjour and peer-to-peer Wi-Fi discovery mechanisms in its
[deployment guide](https://support.apple.com/en-nz/guide/deployment/dep9151c4ace/web).
Start testing on the same local network; do not assume every third-party receiver
inherits Apple's peer-to-peer capabilities. The actual FPS game must be tested:
being able to AirPlay Music does not establish how a game's audio session routes.

Desired software signal path:

```text
iPad --AirPlay/network--> AudioMix receiver --> game volume/EQ --+
Mac music ---------------------> capture --> music volume/EQ --+--> master EQ --> AirPods
```

This is a candidate wireless backend alongside native Bluetooth, not a claim that
AirPlay solves the latency requirement. USB remains preferred when connected.

## Existing software and concrete integration points

[UxPlay](https://github.com/FDH2/UxPlay) is a software AirPlay receiver supporting
macOS. Its documented options provide a practical receiver baseline:

- Audio-only reception and screen mirroring with audio.
- `-vs 0` suppresses video display; it does not eliminate the sender's mirroring work.
- `-vsync no` and `-async no` disable the corresponding timestamp-based playback waits.
- `-al` reports a requested latency; the project says the client appears to ignore it.
- Synchronized audio-only mode can incur roughly two seconds of sender-imposed delay.

These are upstream observations, not AudioMix latency measurements. Compare modes
with the game before selecting one. Current UxPlay code is GPLv3; preserve its
licensing obligations if incorporated or distributed.

Source reviewed locally: commit `ec203121355220dd90278a369eeabb0b8ba4f14a`, cloned to
`/tmp/audiomix-uxplay` for inspection. It has not been vendored into AudioMix.

The [audio renderer source](https://github.com/FDH2/UxPlay/blob/ec203121355220dd90278a369eeabb0b8ba4f14a/renderers/audio_renderer.c)
has an explicit RTP branch that outputs decoded stereo PCM as signed 16-bit
big-endian audio at 44.1 kHz. `-artp` can send it to a loopback UDP endpoint,
avoiding recapture of already-played speaker output. For an initial integration,
AudioMix can receive that stream into a bounded queue. For a tighter implementation,
replace the playback renderer with an in-process decoded-PCM callback and feed
our Core Audio engine directly. This is proposed work, not implemented functionality.

The [receiver callback in uxplay.cpp](https://github.com/FDH2/UxPlay/blob/ec203121355220dd90278a369eeabb0b8ba4f14a/uxplay.cpp)
passes incoming audio to the renderer. That earlier callback is not already a PCM
interface: it still needs the relevant AAC/ALAC decoding stage. Do not connect its
encoded bytes directly to a PCM mixer.

Mac music can use a separate Core Audio process tap. Apple's
[process-tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
documents capturing selected processes, muting their original output, and creating
an aggregate device. AudioMix must exclude its own output and avoid duplicate music
playback or feedback. Capturing Apple's built-in AirPlay receiver as a separate
process is another experiment; no source reviewed establishes that it will expose
that stream separately, so the custom software receiver is the clearer integration.

## Software implementation sequence

1. Establish a baseline using Apple's built-in AirPlay Receiver and the actual game.
   Compare its audio-output picker route with screen mirroring. Record whether Mac
   music and AirPods playback continue, plus audiovisual delay and game performance.
2. Build UxPlay as a separate test receiver and compare nonsynchronized modes with
   video display disabled. Use a distinct service name to distinguish it from the
   built-in Mac receiver. Keep authentication enabled for normal use.
3. Implement the PCM receiver adapter and native mixer: independent gain/EQ for
   iPad and Mac music, master gain/EQ, and selectable Core Audio output.
4. Bound queues, measure jitter/underruns, correct clock drift, and minimize renderer
   waits. Preserve real-time audio scheduling and avoid look-ahead effects.
5. Add direct USB input and automatic wired-first selection. Continue native
   Bluetooth A2DP reception experiments as a separate software backend.

A baseline UxPlay command, once built with its dependencies, is:

```sh
uxplay -n AudioMix -vs 0 -vsync no -async no -pin
```

Select AudioMix on the iPad. This command tests receiver playback only, not the
AudioMix controls. `-pin` authenticates access. A loopback-PCM experiment can then
replace local playback with `-artp 'pt=96 ! udpsink host=127.0.0.1 port=5002 sync=false'`
after a local receiver is ready. Do not claim that disabling timestamp waits
removes delays before packets arrive, or that AirPods output becomes delay-free.

The local environment has CMake, pkg-config, and Homebrew, but pkg-config could
not locate GStreamer or libplist. UxPlay was inspected, not built or run; no
system-wide dependency installations or AirPlay setting changes were performed.
There are no end-to-end game or AirPods latency measurements yet.

## Native Bluetooth receiver test implementation

The first portable-device attempt reported that the Mac was "not supported".
That message alone does not establish whether service discovery, pairing, or AVDTP
negotiation failed. The app log and the portable device's model/OS were requested.
Build 0.2 adds language metadata and locally validated SDP attributes, connection
notifications, raw signaling replies, visible failure stages, and renewal of the
SDK's timed audio-device class after expiry. It passes the local tests; no successful
portable-device connection or fix for this particular rejection is claimed yet.
Reading bluetoothd's unified logs from the agent session was denied by the sandbox.

The user's 0.2 log now locates the failure before listener registration: Bluetooth
authorization=3 (allowed), manager state=5 (powered on), local controller available,
but `publishedServiceRecordWithDictionary:` returned nil. This rules out an
undetermined/denied CoreBluetooth authorization state at that time, but does not
identify the Classic Bluetooth service-publication failure. The iPad's rejection
cannot yet be attributed to our AVDTP responder, since it never started.

Version 0.3 retries the full record using explicit UUID objects and default
transient lifetime. Apple's documentation permits both the NSData and UUID object
representations; this is a compatibility experiment, not a confirmed fix.
[Chromium's native implementation](https://raw.githubusercontent.com/chromium/chromium/main/device/bluetooth/bluetooth_socket_mac.mm)
uses explicit UUID objects with the same public publication API. If both full
records fail, five temporary controls compare custom RFCOMM, custom L2CAP with
automatic versus AVDTP PSM, and compact A2DP with automatic versus AVDTP PSM.
They report actual assignments, remove each successful control, and never count
diagnostic publication as a working receiver. No admin privileges, persistent
services, system modifications, or Bluetooth daemon restarts are introduced.

The user's 0.3 log returned non-nil objects for the zero-port RFCOMM/L2CAP and
compact A2DP controls, but reported no usable port. The following compact fixed
0x0019 probe returned the same handle and PSM zero. This makes the fixed/automatic
comparison inconclusive; stale/rewritten results are possible, not proven.
Chromium's implementation explicitly notes that passing zero may not allocate a
random channel/PSM. The 0.3 zero-port controls were insufficient evidence of
working basic service publication.

Version 0.4 uses only explicit nonzero ports and unique ServiceIDs (SDP attribute
0x0003). It starts with the compact audio descriptor on 0x0019, and requires the
returned ServiceID and all requested attributes to match. Optional name/language
metadata is omitted from that initial descriptor; all required transport, codec
profile and speaker-feature checks remain. Failure triggers six controls using
RFCOMM channel 7, custom L2CAP and compact A2DP on 0x100f/0x0019, then named A2DP
on 0x0019. Custom classes are unique per probe as well. Raw returned attributes,
post-readiness authorization and strict local verification results are logged.
An alternate PSM is never used for the audio receiver. These are local experiments;
none yet proves remote visibility or incoming A2DP ownership.

The user tested AirPlay and found its delay unacceptable. The current test path is
therefore the built-in Mac Bluetooth radio, with no external receiver or dongle.
The new app implements a small AVDTP acceptor, SBC decoding via LGPL libsbc, and
selectable AudioQueue playback in user space. It is not a kernel extension and
has no driver installation step. Its declared endpoint supports SBC only; AAC and
AVRCP are not implemented. Audio service publication and incoming channel ownership
remain platform feasibility gates.

Validation completed: application builds with project warnings treated as errors;
bundle and library signatures pass strict verification; sanitizer tests pass for
negotiation, media parsing/decoding, all 128 advertised codec configurations, and
30,000 malformed inputs. GUI automation access was not approved, so no new live
permission, pairing, or audio result is claimed. An attempted sandboxed
LaunchServices launch returned kLSNoExecutableErr despite the verified executable
being present; a normal user launch still needs checking.

Implementation references:

- [Apple incoming L2CAP notification API](https://developer.apple.com/documentation/iobluetooth/iobluetoothl2capchannel/register(forchannelopennotifications:selector:withpsm:direction:))
- [Bluetooth AVDTP specification](https://www.bluetooth.com/specifications/specs/a-v-distribution-transport-protocol-1-3/)
- [BlueZ protocol constants/reference](https://github.com/bluez/bluez/blob/master/profiles/audio/avdtp.h)
- [SBC library source](https://kernel.googlesource.com/pub/scm/bluetooth/sbc/)

## Input selection policy for the application

Apply preference **per source device**, not globally across all inputs. An attached
microphone or a different iPad must not replace the selected iPad's stream.

Default mode is Auto: choose a healthy wired stream for that iPad; otherwise choose
its selected healthy wireless stream (AirPlay or, if achieved, native Bluetooth). Device presence alone is insufficient. Open the new
route and establish valid PCM delivery before switching. Silent PCM counts as valid
audio; do not use signal amplitude as a health check.

Persist gain, EQ, and mute on the logical iPad source, independent of transport.
Use only one transport for that source at a time to avoid duplicate game audio.
On replacement, discard stale queued data and use a short gain ramp to limit clicks.
An uninterrupted or phase-aligned handover cannot be promised. Apply a short
stability window to prevent rapid switching when a cable connection is intermittent.

If wired disconnects, resume the selected wireless transport only when the iPad has actually established
that route and valid frames arrive. The Mac cannot assume it can force the iPad's
system audio route; show reconnect instructions if user action is needed. If source
identity cannot be matched reliably across USB and Bluetooth, ask the user to link
the two entries rather than guessing from their names.

Offer Auto, Wired only, and explicit wireless transport selection; default to Auto. Keep output selection
independent, so changing iPad input does not deliberately switch AirPods away.
When neither iPad route is healthy, mute that input while Mac music continues.

## Latency acceptance

Measure a direct iPad → AirPods baseline, USB → Mac → AirPods, and (if achieved)
Bluetooth → Mac → AirPods on the same hardware. Record AirPods model, OS versions,
game, microphone/voice-chat state, buffer sizes, and dropouts. Use repeated trials
and report median and tail delay; listening alone and API latency fields are not
end-to-end measurements. A high-speed recording of a repeatable visual/audio game
event can estimate audiovisual delay; use calibrated capture for precise values.

The first prototype should add as little delay as possible over the direct baseline.
No under-10-ms end-to-end claim applies to AirPods output. Apple's
[latency guidance](https://support.apple.com/en-nz/105040) explicitly identifies
Bluetooth output as a latency source. Real-time scheduling protects mixer deadlines
but cannot remove codec or radio buffering.

## Hardware probe procedure

1. Build and run `--validate` as described in the README.
2. With the iPad available, run `--listen 60`. Grant the requested Bluetooth access.
3. Use normal macOS Bluetooth settings to make the Mac available for pairing if
   necessary; select the Mac on the iPad and attempt an audio connection.
4. Record publication status, actual PSM, incoming channel status, and packet lengths.
   Do not expect playback from this discovery-only tool.
5. After exit, the tool removes its service. Verify normal AirPods playback still
   works. Pairing created manually during this experiment may remain.

If the public API cannot supply the fixed PSM, document that specific failure before
investigating another implementation. Do not replace system Bluetooth components
or alter system services as part of this probe.
