#!/bin/bash
#
# Tests the shared release chain (sign-bundle.sh, release.sh preflight) on a throwaway
# bundle, signed ad hoc: no Apple account, no network, a few seconds.
#
#   Scripts/release-chain.test.sh
#
# The bundle has what a real one has that matters here: a main executable, an inner one
# in Contents/MacOS, a resource bundle, InfoPlist.strings, and an ELF file in
# Contents/Resources — the Linux client Batuta will carry, which must stay a sealed
# resource: never signed, and never breaking `codesign --verify --deep --strict`.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-chain-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
pass() { echo "✓ $1"; PASSED=$((PASSED + 1)); }
flunk() { echo "✗ $1" >&2; FAILED=$((FAILED + 1)); }

# Two tiny Mach-O executables; the main one carries a debug-only marker on demand.
printf 'int main(void){return 0;}\n' >"$WORK/main.c"
printf 'const char *marker = "FAKE_DEBUG_DIR"; int main(void){return marker[0] == 0;}\n' >"$WORK/debug.c"
xcrun clang -o "$WORK/main" "$WORK/main.c"
xcrun clang -o "$WORK/debug" "$WORK/debug.c"

cat >"$WORK/app.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
PLIST

# A fresh bundle at $WORK/$1/Fake.app.
make_bundle() {
  local app="$WORK/$1/Fake.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fake_Fake.bundle/Contents/Resources/en.lproj" \
    "$app/Contents/Resources/en.lproj"
  cp "$WORK/main" "$app/Contents/MacOS/Fake"
  cp "$WORK/main" "$app/Contents/MacOS/fake-mcp"
  echo '"x" = "y";' >"$app/Contents/Resources/Fake_Fake.bundle/Contents/Resources/en.lproj/Main.strings"
  echo '"NSMicrophoneUsageDescription" = "z";' >"$app/Contents/Resources/en.lproj/InfoPlist.strings"
  # An ELF header and some bytes, executable, as the Linux client will be.
  printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\076\000' >"$app/Contents/Resources/fake-linux-x86_64"
  head -c 4096 /dev/zero >>"$app/Contents/Resources/fake-linux-x86_64"
  chmod +x "$app/Contents/Resources/fake-linux-x86_64"
  cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Fake</string>
	<key>CFBundleIdentifier</key><string>dev.example.fake</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>NSMicrophoneUsageDescription</key><string>z</string>
</dict>
</plist>
PLIST
  echo "$app"
}

sign() { "$SCRIPTS/sign-bundle.sh" "$1" - "$WORK/app.entitlements" "${@:2}" 2>"$WORK/sign.log"; }

preflight() {
  RELEASE_APP="$1" RELEASE_BUNDLE_ID=dev.example.fake RELEASE_ENTITLEMENTS="$WORK/app.entitlements" \
    RELEASE_HELPERS="Contents/MacOS/fake-mcp" RELEASE_FORBIDDEN_STRINGS="FAKE_" \
    RELEASE_REQUIRED_ENTITLEMENTS="com.apple.security.device.audio-input" \
    RELEASE_PLIST_KEYS="CFBundleIdentifier CFBundleShortVersionString NSMicrophoneUsageDescription" \
    RELEASE_RESOURCE_BUNDLES="Fake_Fake" RELEASE_LANGUAGES="en" RELEASE_SYSTEM_LANGUAGES="en" \
    RELEASE_ICON="" RELEASE_EXTRA_CHECK="${RELEASE_EXTRA_CHECK:-}" \
    "$SCRIPTS/release.sh" preflight >"$WORK/preflight.log" 2>&1
}

# --- sign-bundle.sh ---------------------------------------------------------------

APP="$(make_bundle signs)"
ELF_BEFORE="$(shasum -a 256 <"$APP/Contents/Resources/fake-linux-x86_64")"
if sign "$APP" Contents/MacOS/fake-mcp && codesign --verify --deep --strict "$APP" 2>/dev/null; then
  pass "a bundle with an ELF resource signs and verifies with --deep --strict"
else
  flunk "a bundle with an ELF resource signs and verifies with --deep --strict"; cat "$WORK/sign.log" >&2
fi

INFO="$(codesign -d --verbose=4 "$APP/Contents/MacOS/fake-mcp" 2>&1 || true)"
case "$INFO" in
  *"Identifier=dev.example.fake.fake-mcp"*runtime*|*runtime*"Identifier=dev.example.fake.fake-mcp"*)
    pass "the inner executable has the Hardened Runtime and the identifier <bundle id>.<name>" ;;
  *) flunk "the inner executable has the Hardened Runtime and the identifier <bundle id>.<name>"; echo "$INFO" >&2 ;;
esac

[ "$(shasum -a 256 <"$APP/Contents/Resources/fake-linux-x86_64")" = "$ELF_BEFORE" ] \
  && pass "the ELF resource is left byte for byte" \
  || flunk "the ELF resource is left byte for byte"

printf 'x' >>"$APP/Contents/Resources/fake-linux-x86_64"
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  flunk "the ELF resource is sealed: changing it breaks the signature"
else
  pass "the ELF resource is sealed: changing it breaks the signature"
fi

APP="$(make_bundle unlisted)"
if sign "$APP"; then
  flunk "an inner Mach-O that is not listed is refused"
else
  grep -q "fake-mcp is Mach-O code and is not listed" "$WORK/sign.log" \
    && pass "an inner Mach-O that is not listed is refused" \
    || { flunk "an inner Mach-O that is not listed is refused (wrong reason)"; cat "$WORK/sign.log" >&2; }
fi

APP="$(make_bundle elf-listed)"
if sign "$APP" Contents/MacOS/fake-mcp Contents/Resources/fake-linux-x86_64; then
  flunk "an ELF listed as an inner executable is refused"
else
  grep -q "is not a Mach-O image" "$WORK/sign.log" \
    && pass "an ELF listed as an inner executable is refused" \
    || { flunk "an ELF listed as an inner executable is refused (wrong reason)"; cat "$WORK/sign.log" >&2; }
fi

# --- release.sh preflight, configured for another app ----------------------------------

APP="$(make_bundle preflight-ok)"
sign "$APP" Contents/MacOS/fake-mcp
if preflight "$APP"; then
  pass "preflight passes for another app through the RELEASE_* variables"
else
  flunk "preflight passes for another app through the RELEASE_* variables"; cat "$WORK/preflight.log" >&2
fi

# The folder's name holds "runtime" on purpose: a check that matched the word anywhere in
# `codesign -d`'s output passed this bundle, because the output names its path.
APP="$(make_bundle no-runtime)"
sign "$APP" Contents/MacOS/fake-mcp
codesign --force --sign - --identifier dev.example.fake.fake-mcp "$APP/Contents/MacOS/fake-mcp" 2>/dev/null
codesign --force --options runtime --entitlements "$WORK/app.entitlements" --sign - "$APP" 2>/dev/null
if preflight "$APP"; then
  flunk "preflight refuses an inner executable without the Hardened Runtime"
else
  grep -q "no Hardened Runtime on Contents/MacOS/fake-mcp" "$WORK/preflight.log" \
    && pass "preflight refuses an inner executable without the Hardened Runtime" \
    || { flunk "preflight refuses an inner executable without the Hardened Runtime (wrong reason)"; cat "$WORK/preflight.log" >&2; }
fi

APP="$(make_bundle extra-entitlement)"
cat >"$WORK/extra.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
</dict>
</plist>
PLIST
"$SCRIPTS/sign-bundle.sh" "$APP" - "$WORK/extra.entitlements" Contents/MacOS/fake-mcp 2>/dev/null
if preflight "$APP"; then
  flunk "preflight refuses entitlements other than the declared ones"
else
  grep -q "are not the declared ones" "$WORK/preflight.log" \
    && pass "preflight refuses entitlements other than the declared ones" \
    || { flunk "preflight refuses entitlements other than the declared ones (wrong reason)"; cat "$WORK/preflight.log" >&2; }
fi

APP="$(make_bundle debug-binary)"
cp "$WORK/debug" "$APP/Contents/MacOS/fake-mcp"
sign "$APP" Contents/MacOS/fake-mcp
if preflight "$APP"; then
  flunk "preflight refuses an inner executable that carries review variables"
else
  grep -q "fake-mcp carries review variables" "$WORK/preflight.log" \
    && pass "preflight refuses an inner executable that carries review variables" \
    || { flunk "preflight refuses an inner executable that carries review variables (wrong reason)"; cat "$WORK/preflight.log" >&2; }
fi

# --- Batuta's Linux client: built from the current sources, or no release ---------------
#
# Security close-out, finding 3: make-app.sh copied whatever git-ignored ELF was there and a
# missing one was a warning, so a release could serve a stale client, or none. Batuta's
# release names its check (native/batuta/Scripts/linux-client.sh) as the chain's extra check;
# here it runs on a throwaway source tree, a built "client" and its record.

BATUTA_SCRIPTS="$SCRIPTS/../batuta/Scripts"
SRC="$WORK/batuta-src"
mkdir -p "$SRC/client-linux/crates/batuta-client/src" "$SRC/protocol" "$WORK/client-build"
echo '[workspace]' >"$SRC/client-linux/Cargo.toml"
echo '# lock' >"$SRC/client-linux/Cargo.lock"
echo '[package]' >"$SRC/client-linux/crates/batuta-client/Cargo.toml"
echo 'fn main() {}' >"$SRC/client-linux/crates/batuta-client/src/main.rs"
echo 'syntax = "proto3";' >"$SRC/protocol/batuta.proto"
BUILT="$WORK/client-build/batuta"
cp "$(make_bundle client-source)/Contents/Resources/fake-linux-x86_64" "$BUILT"
export LINUX_CLIENT_ROOT="$SRC" LINUX_CLIENT_ELF="$BUILT" LINUX_CLIENT_STAMP="$BUILT.source"

# A bundle carrying `client` as Batuta's Linux client (or none), signed ad hoc.
batuta_bundle() {
  local app
  app="$(make_bundle "$1")"
  if [ -n "${2:-}" ]; then cp "$2" "$app/Contents/Resources/batuta-linux-x86_64"; fi
  sign "$app" Contents/MacOS/fake-mcp
  echo "$app"
}

batuta_preflight() {
  RELEASE_EXTRA_CHECK="$BATUTA_SCRIPTS/linux-client.sh" preflight "$1"
}

# Refused, for the reason given.
expect_refused() {
  local case_name="$1" app="$2" reason="$3"
  if batuta_preflight "$app"; then
    flunk "$case_name"
  else
    grep -q "$reason" "$WORK/preflight.log" \
      && pass "$case_name" \
      || { flunk "$case_name (wrong reason)"; cat "$WORK/preflight.log" >&2; }
  fi
}

grep -q '^export RELEASE_EXTRA_CHECK="$BATUTA/Scripts/linux-client.sh"$' "$BATUTA_SCRIPTS/release.sh" \
  && pass "Batuta's release runs the Linux client check as its extra check" \
  || flunk "Batuta's release runs the Linux client check as its extra check"

"$BATUTA_SCRIPTS/linux-client.sh" stamp "$("$BATUTA_SCRIPTS/linux-client.sh" sources)" >/dev/null
APP="$(batuta_bundle client-fresh "$BUILT")"
if batuta_preflight "$APP" && grep -q "Linux client built from the current sources" "$WORK/preflight.log"; then
  pass "preflight passes a Linux client built from the current sources"
else
  flunk "preflight passes a Linux client built from the current sources"; cat "$WORK/preflight.log" >&2
fi

expect_refused "preflight refuses a release without the Linux client" \
  "$(batuta_bundle client-missing)" "no Linux client in Fake.app"

cp "$BUILT" "$WORK/other-client"; printf 'x' >>"$WORK/other-client"
expect_refused "preflight refuses a Linux client that is not the recorded build" \
  "$(batuta_bundle client-other "$WORK/other-client")" "is not the one built and recorded"

echo 'fn main() { changed(); }' >"$SRC/client-linux/crates/batuta-client/src/main.rs"
expect_refused "preflight refuses a Linux client built from other sources than the current ones" \
  "$(batuta_bundle client-stale "$BUILT")" "built from other sources than the current ones"

rm "$BUILT.source"
expect_refused "preflight refuses a Linux client with no record of its sources" \
  "$(batuta_bundle client-unrecorded "$BUILT")" "no record of the sources"
unset LINUX_CLIENT_ROOT LINUX_CLIENT_ELF LINUX_CLIENT_STAMP

# --- release.sh dmg -------------------------------------------------------------------

# A bundle rebuilt after `full` is signed but not the notarized one: `dmg` refuses it
# before building, signing or submitting anything (no credentials needed to say so).
APP="$(make_bundle not-released)"
sign "$APP" Contents/MacOS/fake-mcp
if RELEASE_APP="$APP" RELEASE_HELPERS="Contents/MacOS/fake-mcp" NOTARY_PROFILE="" \
    "$SCRIPTS/release.sh" dmg >"$WORK/dmg.log" 2>&1; then
  flunk "dmg refuses an app that is not the Developer ID, stapled one"
else
  grep -q "is not signed with Developer ID — run \`full\` before \`dmg\`" "$WORK/dmg.log" \
    && ! test -e "$WORK/not-released/dmg-stage" \
    && pass "dmg refuses an app that is not the Developer ID, stapled one" \
    || { flunk "dmg refuses an app that is not the Developer ID, stapled one (wrong reason)"; cat "$WORK/dmg.log" >&2; }
fi

echo
if [ "$FAILED" -ne 0 ]; then
  echo "✗ release chain: $FAILED of $((PASSED + FAILED)) failed" >&2
  exit 1
fi
echo "✓ release chain: $PASSED passed"
