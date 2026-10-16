# Device volume controls

AudioMix Wired Test 0.7 adds **Device volumes…** in the main window and application
menu (Command-D). The separate resizable panel lists This Mac and currently
connected capture inputs, with a volume slider, percentage, mute and Play/Stop
or Enable/Disable button. Closing the panel keeps playback running.

USB inputs start only when explicitly selected and played. Each input has its
own capture/output instance, atomic software gain and bounded PCM queue. Gain
and mute are stored by AVFoundation's persistent device ID. Mute retains the
slider level so unmuting restores it; disconnected inputs leave the panel and
their settings remain available on reconnect. No Bluetooth accessory is treated
as a source merely because it is paired.

An iPad can expose both an enabled USB audio input and a screen/audio input.
These are alternative capture routes, labeled in the row details. Play one route
per physical device. On the test iPad, starting screen/audio caused the enabled
USB-audio entry to disappear; discovery updates the panel without interrupting
the active route. Multiple independent physical USB sources are supported by the
controller but have not been tested together on hardware.

## Mac audio

Enable This Mac to adjust other apps' audio playing to the output selected in
the main window. Apps explicitly routed to a different output remain outside
this control. macOS may prompt for System Audio Recording access. This path
requires macOS 14.2+, and was started successfully on macOS 26.1 with the user's
Bluetooth headset.

The native implementation uses a device-scoped private Core Audio process tap.
Translating and excluding AudioMix's process is mandatory: all USB playback and
the Mac replay belong to that process and must never be fed back into the tap.
The tap uses `CATapMutedWhenTapped`, so original app output is suppressed while
our IOProc reads it. Disabling or destroying the tap restores native app output.

The tap and physical output share a private aggregate and a single realtime
IOProc. Software gain runs directly from input to output in that callback, with
no added application ring buffer. Physical microphone input streams, if present,
are disabled for this IOProc before it starts; only identified tap streams are
read. Setup fails if this cannot be done. The initial implementation supports
a mono/stereo Float32 output with one physical output stream. A disconnected
output, invalid callback buffers or a stalled callback releases Mac control.

The USB game-audio path retains its existing queue and AUHAL output. AudioMix
does not change system default devices, device sample rates, hardware buffer
sizes or the AirPods hardware volume. No audio is written to disk.

## Verification

`sh tools/test-wired.sh` runs sanitizer-backed PCM/ring tests plus Mac gain tests:
independent Mac/USB gain, mute, stereo/planar/mono mapping, ignoring physical
input buffers, malformed buffer lengths, clipping and non-finite samples.
The app builds with warnings as errors and its bundle signature is verified.

Native UI testing exercised independent slider/mute updates, live iPad playback
alongside an enabled Mac tap on the Bluetooth headset, dynamic removal of the
alternate iPad route, and closing the panel without stopping either audio path.
The user verified audible simultaneous playback before the new panel was added;
audible isolation with the new individual controls and end-to-end delay are
separate listening/measurement checks.

The final build restored the saved Mac level (51%) and iPad level (50%) after
restart, both unmuted. On the same headset, the Mac callback confirmation logged
9,216 rendered frames; the live USB snapshot showed 1,331,200 captured PCM frames,
1,322,496 rendered frames, zero invalid buffers and zero output callback errors.
Starting the input from the panel selected it in the main window and displayed
the active stream's statistics. The panel was reopened with both paths running.

Apple documents the process-tap approach and system audio permission in
[Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps).
