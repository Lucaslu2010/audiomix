# Live GUI testing — macOS 26.1 (25B78), 2026-10-15

Computer use was authorized by the user for this session. AudioMix was launched,
its Start button exercised, and the visible log inspected. Rebuilt ad-hoc signed
versions requested Bluetooth authorization again. The computer-use provider blocks
the macOS authorization-alert app; grants completed outside that blocked UI, and
AudioMix then reported authorization 3 and manager state 5. No Bluetooth privacy
toggles, radio resets, pairing deletion, system files, or security settings changed.

## Confirmed in version 0.6 at 20:10:15

Full exported log: [AudioMix-live-0.6.log](../build/AudioMix-live-0.6.log).

- Standard Audio Sink first: handle 0x4f49110b, actual PSM zero, no requested ServiceID.
- Custom class followed by Audio Sink on PSM 0x0019: nil.
- Audio Sink followed by custom class: the same unidentified PSM-zero record.
- Subscribing to incoming 0x0019 notifications *before* publication succeeds, but
  does not change these results. Notification subscription is not transport ownership.
- Custom RFCOMM channel 7: requested identity and semantic attributes match.
- Custom L2CAP PSM 0x6cbf: requested identity and semantic attributes match.
- Custom L2CAP PSM 0x0019: nil.
- Custom-first Audio Sink PSM 0x6cbf: requested identity and semantic attributes match.
- Standard/named Audio Sink: same unidentified PSM-zero record.
- Older documented IOBluetoothAddServiceDict: exported, returns success, but returns
  the same unidentified Audio Sink record at PSM zero. It does not solve registration.

Version 0.4 incorrectly rejected valid generic controls because it compared
sequence sizes and integer/UUID widths before comparing values. Returned macOS
objects normalize uint16 to uint32 and UUID16 to UUID32, changing parent sequence
sizes too. Version 0.5 fixes semantic comparison; separate request construction
tests retain strict width checks. Matching values does not prove the wire widths.

These tests isolate an unresolved standard-transport/platform integration problem.
They do not establish the precise internal cause, or impossibility of every
software-only approach. Existing public APIs have not produced our own standard
A2DP listener on this Mac. The code never counts an unidentified record as ours
and never removes it.

## Version 0.7 experiment

An explicit, default-off option retains standard registration attempts first and
then tries a custom-first Audio Sink record on a dynamic PSM. If identity, values
and the requested port match, the app subscribes to that port and runs its own
AVDTP/SBC responder. The visible stage and log label this an experiment. Standard
PSM 0x0019 remains the requirement for the normal mode. iPad discovery, acceptance
of a custom port/class list, incoming packets, playback and latency need separate
evidence. Local listener startup alone must not be reported as working iPad audio.

Confirmed through the GUI at 20:14:24 and 20:15:58:

- First experimental start: requested/returned PSM 0x8c09, matching unique ServiceID
  and semantic profile attributes, incoming notification subscription non-nil.
- Visible stage: `EXPERIMENT: listening on 0x8c09; iPad unverified`.
- Stop at 20:15:47: owned SDP removal returned success; the GUI returned to Stopped.
- Restart: a fresh owned record at PSM 0x4ab7 passed the same checks and reached
  the experimental listening stage again. No duplicate/zero port was accepted.
- The temporary class-of-device setter returned success, but read-back was zero
  rather than 0x240414. Renewal could not verify it and stopped. This means an
  effective audio-device identity change has **not** been established.
- A baseband link event occurred during the first session, but no signaling or
  media channel was delivered. Packet and PCM counters remained zero.
- The receiver was left running in experimental mode after the second start.
  System Settings explicitly showed this Mac discoverable as “nekomiya mana”.

Full exported evidence: [AudioMix-live-0.7.log](../build/AudioMix-live-0.7.log).
No iPad audio success is claimed. The app has no computer-use surface for the
physical iPad, so the next interoperability check requires selecting this Mac on
that device and watching for incoming signaling/media rather than a baseband event.

## iPad attempt: no working audio connection

The user subsequently tested selecting the Mac on the iPad. They clarified that
“Connected” appeared only briefly, followed by automatic disconnection, and the
Mac never became an audio output. This is not a successful persistent connection
or an A2DP pass; the earlier provisional report of a successful connection is
superseded by this correction.

The live GUI showed four connect notifications at 20:19:20 (twice), 20:19:40 and
20:19:55. The `links` counter counts notification events, not concurrent or proven
stable connections. Signaling/media channel count, media packet count and decoded
PCM frames all remained zero. No AVDTP request reached the app, so there is no
evidence of a rejection by our protocol responder. The exact remote disconnect
reason is not recorded: this build does not subscribe to per-device disconnect
notifications or capture remote SDP queries.

Evidence: [AudioMix-iPad-attempts-0.7.log](../build/AudioMix-iPad-attempts-0.7.log).
The custom-port experiment failed to establish usable audio with this iPad. Do
not recommend repeated re-pairing or claim that a keepalive fixes this result.
Standard AVDTP service exposure/transport integration remains unresolved. The
[Bluetooth SIG A2DP test suite](https://files.bluetooth.com/wp-content/uploads/dlm_uploads/2025/02/A2DP.TS_.p21.pdf)
requires Audio Sink discovery attributes and the AVDTP PSM; the custom-class,
dynamic-port listener was a local interoperability experiment rather than a
substitute for that standard profile.

## Daemon trace and receiver-initiated experiment (0.8)

Console.app can read the live daemon trace even though the agent's sandbox does
not permit the `log` command. During a controlled GUI stop/start, bluetoothd
explicitly logged PSM 0x0019 registration failing with result **402**, followed by
the client error 1801 / 0x709. See [selected trace entries](daemon-registration-evidence.log).
The [Open Interface status definitions in AOSP](https://android.googlesource.com/platform/system/bt/+/8289925/embdrv/sbc/decoder/include/oi_status.h)
map 402 to `OI_STATUS_PSM_ALREADY_REGISTERED`. Applying that mapping to this Apple
trace is an inference, strongly consistent with an occupied standard AVDTP server
port. The trace alone does not identify its owner. No existing server was removed.

The [Bluetooth SIG AVDTP test suite](https://files.bluetooth.com/wp-content/uploads/dlm_uploads/2025/02/AVDTP.TS_.p22.pdf),
section 4.5.1.5 and 4.5.2.3, covers a Sink acting as Initiator and opening the
media L2CAP channel. Version 0.8 adds an independent Mac-initiated experiment:
select the iPad from recent/paired devices, connect to its remote PSM 0x0019,
Discover its source endpoints, obtain SBC capabilities, SetConfiguration, Open,
open a second outgoing channel to its PSM 0x0019, prepare playback, and Start.
No local PSM 0x0019 service publication is needed by this path. This may avoid the
server-port conflict; iPadOS acceptance and audio routing remain experiments.

The new C initiator is tested through the complete synthetic negotiation sequence,
fallback across unavailable/incompatible endpoints, invalid responses, message-type
preserving signaling fragmentation, and 30,000 malformed responses under ASan/UBSan.
Existing responder/media tests still pass. These tests do not prove iPad behavior.

`tools/bluetooth-api-inventory.m` also inventories runtime metadata from the loaded
public CoreBluetooth and IOBluetooth frameworks. It invokes no private selectors,
makes no device connections, and changes no Bluetooth settings. Its output is
saved in `build/bluetooth-api-inventory.txt`; selector presence alone is not
evidence of a supported way to take over the existing audio transport.

## Sampled app deadlock: fixed in 0.8

Activity Monitor's Sample Process captured the unresponsive 0.7 process. The
[saved sample](../build/AudioMix-0.7.sample.txt) shows the main thread waiting in
AppKit text layout while `com.apple.bluetooth.iobluetooth.coordinatorQueue` enters
`AMReceiver basebandConnected:device:` → `AppDelegate append:` → NSTextView/text
storage updates and waits on another text-storage lock. A Bluetooth notification
was touching AppKit from a background queue. This is an application bug, separate
from standard-port registration failure; earlier zero-channel observations during
a frozen process cannot isolate radio/profile behavior.

Version 0.8 marshals receiver and initiator connection/data/close callbacks to the
main queue, copying callback packet data before the callback returns. The UI log
also marshals independently to main. Receiver open callbacks ignore channels it
does not own. The UI counter now says `link events` because notifications do not
measure concurrent or persistent connections. A regression test invokes a
connection notification and UI logging from background queues and checks delivery
on main; it passes alongside the protocol/media sanitizer tests.

## Actual outgoing test and fixed incoming startup (0.8)

The GUI selected the user's iPad from the recent/paired list (`paired=1`) and
started the Mac-initiated route at 20:48:13. The asynchronous API initially returned
success, then delivered `0xe00002bc` (IOKit general error) at 20:48:21. No signaling
channel, AVDTP response, media packet or PCM frame was established. The GUI remained
responsive. Evidence: [exported app log](../build/AudioMix-outbound-0.8.log).

A paused Console selection was copied through TextEdit into
[the filtered L2CAP trace](../build/AudioMix-daemon-l2cap-0.8.txt). Its retained
window begins at 20:48:41, **after the recorded outgoing failure**, so it cannot
identify that attempt's exact underlying cause. It contains repeated native
IOBluetooth PSM-25 open timeouts and incoming PSM-1/25 requests, plus SDP service
summaries. Their relationship to the earlier app operation is unresolved; no
remote rejection or exact HCI disconnect reason is established by this export.
There is no application-level retry loop in the initiator. The failed session was
quit through the app menu before restarting the incoming listener.

After a clean relaunch at 20:55:59, the incoming custom-port experiment started
at 20:56:10 on PSM `0x5ad7` with a matching unique ServiceID. The ineffective
temporary class override was unchecked for this test. Standard-port publication
still failed verification in the same way. An immediate replayed link event named
the AirPods, demonstrating why generic link events must not count as iPad success.
This new listener startup is verified, but a new physical iPad selection after the
thread fix has not yet been confirmed. No new iPad audio success is claimed.
The fixed listener was left running for that check; its saved startup log is
[AudioMix-incoming-startup-0.8.log](../build/AudioMix-incoming-startup-0.8.log).

## Accessory-disconnection report and mirrored iPhone tests

The user subsequently confirmed that the 0.8 incoming route still disconnects,
and reported that it also disconnects the iPad's other Bluetooth connections.
This supersedes the pending post-fix test above. The app log records an iPad link
event at 20:59:52, still with zero channels/packets/PCM. Other Mac-side link events
follow, but those notifications cannot establish which iPad accessories dropped
or whether a remote Bluetooth process restarted.

The user authorized testing with iPhone Mirroring instead of requesting manual
iPad attempts. At 21:01:47 the receiver was stopped through its GUI. Owned SDP
removal returned success. The temporary device-class option had already been off.

The mirrored iPhone's Bluetooth page identified the phone as
`harkonnen.wh1spered.com`. Its Apple Watch showed connected. At 21:03 the AirPods
also showed connected. With the local receiver stopped, one outgoing attempt to
that exact phone was started at 21:04:22. It timed out at 21:04:34 before any
AVDTP channel or packets. The Watch remained connected; the AirPods subsequently
showed disconnected. Automatic AirPods switching and other system behavior have
not been ruled out, so this observation does not prove an all-accessory reset.
Later the phone displayed “Pairing Unsuccessful” for `nekomiya mana`; the alert was
dismissed without deleting any pairing or changing Bluetooth power/settings.
The Mac's `paired=1` cache is insufficient evidence of a currently usable pairing.
At 21:13 both the AirPods and Watch again showed connected on the mirrored phone,
without toggling Bluetooth, re-pairing, or changing accessory settings.
Evidence: [saved test log](../build/AudioMix-phone-attempt-0.8.log) and direct
computer-use screenshots in the session. The failed outgoing session was quit.

### Version 0.9 containment and inspection

- Receiver startup returns immediately without requesting Bluetooth access or
  publishing services. The GUI disables receiver/class/custom-port controls.
- The source button now performs SDP inspection only, querying Audio Source
  UUID 0x110A and recording the result/cache timestamp/advertised PSM. It never
  opens AVDTP signaling or media channels. Underlying SDP can still require a
  baseband connection; this is not a passive radio capture.
- The retained, non-GUI initiator path requires successful SDP preflight before
  opening standard AVDTP. Unknown channel callbacks and stale query completions
  are ignored. Query delegates are retained through completion. Public SDP has
  no cancellation method; after timeout no second outstanding query is started.
- Mock-based tests verify no radio access from retired startup, no audio-channel
  request during inspection, successful/missing source handling and stale callback
  isolation. Protocol/media sanitizer tests and build pass.

The 0.9 GUI was opened and its disabled controls verified at 21:08:55. A new
Bluetooth permission prompt appeared when Devices was clicked at 21:09:02.
The computer-use provider does not expose that permission-alert app, so the
user was asked only to approve this Mac prompt. No live 0.9 SDP result has yet
been obtained; the new query tests are mocks, not phone interoperability proof.

An automatic approval review rejected an attempted checkbox click, interpreting
it as re-enabling the custom advertisement. That click was not retried. Receiver
stop and successful record removal had already been verified, and the independent
outgoing test made no local publication. Version 0.9 removes that option from the
runnable GUI rather than relying on a checkbox state.

## Authorized 0.9 phone inspection and unfiltered 0.10 follow-up

At 21:19:47 the older running 0.9 copy reported authorization 3 but manager state
3. The source had been rebuilt while that earlier process was open, so it was
closed and the final 0.9 binary launched at 21:22:55. The new process reported
authorization 3 and powered-on state 5 at 21:23:07. System Settings → Privacy &
Security → Bluetooth showed the AudioMix entry enabled. No toggles were changed.
Rebuilding an ad-hoc signed app can change its TCC identity; do not rebuild an app
while leaving an earlier copy waiting for permission. No valid signing identity
was found in the available keychains; no certificate or keychain settings changed.

iPhone Mirroring was resumed and the phone name verified on its Bluetooth page.
The Watch showed connected and AirPods disconnected before the query. A single
UUID-filtered SDP request started at 21:26:06 and returned immediate status zero,
but no completion reached the app by its 12-second timeout at 21:26:18. At 21:27:59
the outstanding-query guard prevented another request. Thus no Audio Source
absence or presence can be inferred from this timeout, and no AVDTP/media request
was sent. The Watch remained connected during the inspection.
Evidence: [0.9 app log](../build/AudioMix-phone-SDP-0.9.log).

Console was resumed later with an SDP filter. It showed system SDP-cache reads,
but their relationship to the app's stalled request was not established. A new
TextEdit trace export could not be completed because that app became unavailable
to computer use; do not present the old 0.8 L2CAP file as this test's trace.

Version 0.10 changes only the inspection strategy: it logs the pre-query cache
separately, calls unfiltered `performSDPQuery:`, and selects the wanted service
after completion. The unfiltered call is the documented
[Apple API](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/performsdpquery%28_%3A%29?language=objc)
and is used by [Chromium's implementation](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/device/bluetooth/bluetooth_socket_mac.mm).
A [developer's first-hand account](https://zenn.dev/udon_dev/articles/macos-rfcomm-sony-headphones)
also discusses filtered-query non-completion and cache-based alternatives; that
does not prove the same internal defect caused this Mac's failure. Cached service
data is not treated as a fresh response or proof of working routing. Late query
completions are now logged without changing a newer session's state.

Build, signature verification and all mock/protocol/media sanitizer tests pass
for 0.10. The GUI was launched at 21:34:49 and Devices clicked at 21:35:10, producing
a new Bluetooth permission request. The user was asked to allow that alert because
the computer-use provider cannot operate it. The live unfiltered phone result is
still pending; it must not be inferred from the successful mock tests.

## Live 0.10 permission and pairing retry

The existing 0.10 process reported authorization 3 and powered-on state 5 at
21:37:12. On the user's later request to retry the Allow prompt, those values
were verified and Devices successfully listed the 17 cached/recent devices at
21:55:04. No new build, permission reset or Bluetooth-power change was needed.

The mirrored phone was resumed. Before the next query its Watch showed connected
and its AirPods disconnected. The unfiltered query started at 21:56:19. The
pre-query cache returned Audio Source 0x110A, record handle 0x4f49110a, L2CAP PSM
0x0019 and AVDTP/A2DP version 0x0103. Its timestamp was equal to the read time.
Those are compatibility/cache values; they do not prove a fresh over-the-air
response or usable pairing. The app reported timeout at 21:56:31.

Unlike the earlier filtered attempt, the phone visibly presented a numeric
pairing request naming this Mac after the unfiltered query. The Mac's matching
confirmation could not be read or operated: computer use explicitly rejects
`com.apple.UserNotificationCenter` for safety reasons. The phone's first request
expired without completing both ends. Its error was dismissed. The Watch and
AirPods subsequently both showed connected again.

Using the phone's own Bluetooth settings, the Mac entry was brought above the
home-gesture area by scrolling and selected again. This generated a second
pairing request at approximately 22:00. The user was asked to verify the Mac's
matching numeric code and approve the Mac end. An attempted phone-side Pair click
was rejected by automatic approval review because the Mac code had not yet been
verified. It was not retried; confirmation of the matching Mac code is required
before pressing Pair. No completed pairing or audio reception is claimed.
That second request also expired without verified matching-code confirmation.
The expired code is no longer valid. The phone's error was dismissed, the
[0.10 app transcript](../build/AudioMix-phone-SDP-0.10.log) exported, and the app's
Quit menu invoked to end the outstanding native query session. No services were
published or audio channels opened by this build during the test.

## User-ready retry at 22:16

After the user replied ready, Mirroring was resumed and the unchanged 0.10 build
reopened. Devices listed the cached entries without a new permission prompt.
An unfiltered query to the identified phone started at 22:17:10 and timed out
at 22:17:22. The pre-query Audio Source compatibility/cache values matched the
previous test. No new numeric pairing dialog was observed on this attempt.

The Mac Bluetooth pane confirmed power on and discoverability as `nekomiya mana`.
The phone's nearby list showed another Mac but not this Mac. Its saved list still
contained `猫宫又奈`; the user was asked whether that was this Mac's previous name
before any attempt to select that entry. It was not selected without identification.
The phone's Watch remained connected in the observed screens; AirPods were already
disconnected at baseline. No all-accessory reset was observed in this retry.

A coordinate focus click was rejected by automatic review as possibly selecting
an unintended device. It was not retried. The exposed Raise window action was
used instead, followed by scrolling without selecting another device.

Evidence: [ready-session retry log](../build/AudioMix-pairing-retry-0.10.log).
The app's Quit menu was invoked to stop the outstanding native session while
waiting for the saved-entry identity clarification. No build or signing changes
were made during this retry, and no new audio receiver was advertised.
