# Bluetooth research test app

This is a retained research experiment, separate from the working USB mixer.

## Bluetooth test app

An experimental native **A2DP/SBC receiver** is implemented and built at
`build/AudioMixBluetooth.app`. It uses the Mac's built-in radio through public
IOBluetooth APIs. It does not install a kernel driver, replace Bluetooth system
components, or require an external receiver/dongle.

**Current build: 0.10, service inspection only.** The user reported that selecting
our experimental receiver disconnected the iPad's other Bluetooth accessories.
The listener was stopped and its owned SDP record removed successfully. Local
receiver startup, custom-port publication and device-class overrides are disabled
in the runnable build. **iPad/iPhone audio is not working.**

Version 0.8 fixed a sampled UI/Bluetooth callback deadlock, but incoming iPad tests
still delivered zero audio channels. Standard AVDTP registration fails; daemon
status is consistent with an occupied standard port. A separate Mac-initiated
attempt failed for the iPad and timed out for the mirrored iPhone before audio
negotiation. The phone also displayed a pairing failure despite the Mac's cached
`paired=1` value. These findings do not establish an exact disconnect cause or
end-to-end latency. See [live test evidence](docs/live-testing.md).

### Build and test

```sh
sh tools/build-bluetooth-test.sh
sh tools/test-bluetooth-receiver.sh
open build/AudioMixBluetooth.app
```

Requires Xcode command-line tools on macOS 14 or newer. The resulting app targets
the machine's current architecture. No Homebrew dependencies or downloads are
needed to build; the SBC library source is included in `vendor/libsbc`.

### Inspect the phone's services

1. Open `build/AudioMixBluetooth.app`, verify version **0.10** in the log, and click
   **Devices**. Allow the expected macOS Bluetooth prompt if shown, then click
   **Devices** again.
2. Select the intended phone/iPad from recent/paired devices and click **Inspect
   source**. A cached entry does not prove a usable current pairing.
3. The app logs the selected device's pre-query Audio Source cache and timestamp,
   then requests its full SDP records and selects Audio Source (UUID 0x110A)
   afterward. Cached values are explicitly labeled and do not establish a fresh
   remote response. Completion logs its status, timestamp, attributes and AVDTP port.
   The GUI does not publish a local service or request audio channels.
4. Save the log with **Save Test Log…**. Stop/timeout ignores late query results;
   the public SDP API does not expose cancellation of the underlying system query.
   An outstanding query prevents another query from starting until it completes
   or the app is relaunched. There is no app retry loop.

The source initiator code retains AVDTP negotiation for future investigation, with
SDP preflight required. It is not exposed by the current GUI. The old local
receiver/probe construction code remains for research and tests; ordinary receiver
startup returns immediately without contacting Bluetooth. Do not follow earlier
0.7/0.8 custom-port pairing instructions.

### Protocol code retained and tested

- One SBC sink endpoint, 44.1/48 kHz, mono or stereo (mono expands to stereo output).
- AVDTP discovery/capabilities, configuration, open, start, suspend, reconfigure,
  close and abort; bounded signaling fragment reassembly.
- RTP/SBC parsing, SBC fragmentation, duplicate/loss checks, decoded PCM playback.
- Output selection and volume, bounded app queue, connection logs and counters.

This is a receive/playback experiment, not yet the complete mixer. It has no AAC,
AVRCP remote controls, EQ, independent Mac music processing, USB switching, or
microphone return to the iPad. Mac music can still mix through the normal OS audio
output if both apps use the same device. Test voice chat separately.

The queue control is a **maximum retained PCM queue**, not a guaranteed latency or
a deliberate startup delay. Small limits can drop part of a large incoming packet.
The audio callback renders 256 frames into each of three AudioQueue buffers; device,
codec, OS and AirPods buffering add further delay. App queue statistics are not
end-to-end latency. There is no adaptive sample-rate drift correction yet, so long
sessions may underrun or drop frames. Silent-fill counts include startup and pauses.

### Verification

The descriptor tests verify the locally decoded Audio Sink UUID, L2CAP PSM and
integer widths, AVDTP/A2DP profile versions, optional service-name language metadata,
and speaker feature. They reject stale/missing identities and zero/wrong PSMs.
The retired receiver code validates a returned record against its request. Local
validation does not establish that the portable device can see/accept that record.

The sanitizer-enabled tests cover the stream lifecycle, malformed configurations,
signaling/media fragmentation, RTP headers and sequence wrap, bounded queue behavior,
all 128 advertised SBC configurations, and 30,000 deterministic malformed inputs.
The initiator tests cover negotiation, endpoint fallback, response validation,
fragmentation and another 30,000 malformed responses. A thread regression test
checks that Bluetooth connection notifications and log updates reach the main
thread before touching application state/UI.
Additional mock-based tests verify that retired receiver startup does not touch
Bluetooth, source inspection never requests audio channels, missing sources fail,
and stale query/channel callbacks cannot affect a newer attempt.
They do not establish iPad interoperability or Bluetooth latency.

libsbc is dynamically linked and its unmodified source, provenance, and LGPL license
are in [vendor/libsbc](vendor/libsbc/UPSTREAM.md).

## Research and older probe

[Research notes](docs/bluetooth-investigation.md) cover the software-only constraint,
AirPlay findings and wired-first selection policy. The user tested AirPlay and found
its latency unacceptable for the intended game. USB is now the active capture
test path, with Wi-Fi under investigation; the Bluetooth receiver remains disabled.

The earlier discovery-only probe is retained under `tools/bluetooth-probe.m` and
`tools/build-probe.sh`. It does not negotiate or play audio. Use the new app above
for the current receiver experiment.
