#!/bin/sh
# Signs the backend with the Developer ID identity (else the local
# "iOdus Local Signing" identity), with the hardened runtime.
# A stable signature lets the Keychain items of xodus-cli keep their access
# after each rebuild. With ad-hoc signing, each build is a new program to macOS.
# Run this after each `cargo build` of the fork.
# Usage: sign-backend.sh [release folder]
set -eu

RELEASE=${1:-$HOME/projects/iodus-xodus/target/release}
. "$(dirname "$0")/signing.sh"
echo "Sign with: $IDENTITY"

for name in xodus-cli xodus-service; do
  binary="$RELEASE/$name"
  [ -f "$binary" ] || continue
  # Sign a copy and rename it, so that a running process keeps its old file.
  tmp="$binary.signing"
  cp "$binary" "$tmp"
  # shellcheck disable=SC2086
  codesign --force $SIGN_FLAGS --entitlements "$(dirname "$0")/../Resources/xodus-cli.entitlements" \
    -s "$IDENTITY" -i "com.burghr.iodus.$name" "$tmp"
  mv -f "$tmp" "$binary"
  codesign -d -r- "$binary" 2>&1 | tail -1
done
