#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
probe_revision=3854a5df4a5a6dee71ffce4d8befc2ea356a8065
if [ ! -d research/idevice/.git ]; then
  mkdir -p research
  git clone https://github.com/jkcoxson/idevice.git research/idevice
  git -C research/idevice checkout --detach "$probe_revision"
fi
if [ "$(git -C research/idevice rev-parse HEAD)" != "$probe_revision" ]; then
  echo "The research checkout differs from the reviewed idevice revision. Review it before building." >&2
  exit 1
fi
export CARGO_HOME="$PWD/build/cargo-home"
export CARGO_TARGET_DIR="$PWD/build/coredevice-target"
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --locked --manifest-path tools/coredevice-probe/Cargo.toml --jobs 2 "$@"
echo "Built $CARGO_TARGET_DIR/debug/audiomix-coredevice-probe"
