# libsbc provenance

Unmodified source/header subset from BlueZ's SBC library, release 2.2:
https://kernel.googlesource.com/pub/scm/bluetooth/sbc/

Commit: b3deb8a5dcfb42d8c10ba1f2f1ac9bd7bf7271cc

Files: sbc.c, sbc_primitives.c, and upstream sbc/*.h; COPYING.LIB is the LGPL
2.1 license. Source files identify LGPL-2.1-or-later. Copyright notices remain
in each file. The AudioMix build uses a separate Darwin byte-order compatibility
header and the generic high-precision build; upstream files are unchanged.

The app dynamically links Contents/Frameworks/libsbc.dylib. Users can rebuild
that library or the entire app with tools/build-bluetooth-test.sh. The app is
ad hoc signed without a hardened-runtime/library-validation restriction, so
the library can be replaced and the bundle re-signed with codesign --force
--sign -. The complete corresponding upstream source is available at the
commit URL above; the subset used to build this binary is included here.

No BlueZ or BTstack protocol implementation is incorporated. AudioMix's small
experimental AVDTP responder and RTP adapter are implemented in Sources/.
