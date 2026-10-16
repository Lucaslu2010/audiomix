# Third-party source and dependencies

AudioMix's original project code and documentation are licensed under [CC BY-NC 4.0](LICENSE). Third-party code retains its own license and authorship; the root license does not replace or restrict those rights.

## libsbc

The separate Bluetooth research app includes an unmodified source/header subset of BlueZ libsbc 2.2 under `vendor/libsbc/`. Copyright notices and the LGPL-2.1-or-later license are retained. See [provenance and rebuild instructions](vendor/libsbc/UPSTREAM.md) and [the license](vendor/libsbc/COPYING.LIB). The USB mixer does not link libsbc.

## Optional CoreDevice probe

The optional probe uses [idevice by Jackson Coxson](https://github.com/jkcoxson/idevice) under the MIT license, pinned to revision `3854a5df4a5a6dee71ffce4d8befc2ea356a8065`, and Rust dependencies recorded in `tools/coredevice-probe/Cargo.lock`. `tools/build-coredevice-probe.sh` fetches the pinned upstream source into the ignored `research/idevice/` directory. Its license is retained by that checkout and copied into the app when the probe is bundled. `tools/collect-probe-notices.py` collects dependency license notices for packaging.

The published DMG bundles the probe and its third-party notices in `AudioMixWired.app/Contents/Resources/`.

## Research references

The local, unmodified [Device Hub iOS](https://github.com/JaviSoto/device-hub-ios) and idevice reference checkouts are not part of this repository. AudioMix's documentation links to the upstream research sources. This repository does not claim authorship of those projects.
