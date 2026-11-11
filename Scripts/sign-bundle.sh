#!/bin/bash
#
# Signs an assembled .app bundle from the inside out: each inner executable first, then
# the bundle. One signer for the apps under native/ that use the shared release chain
# (Ámbar, Batuta), so the order, the flags and the checks cannot drift between them.
#
#   Scripts/sign-bundle.sh <app> <identity> <entitlements> [<inner executable>...]
#
#   <app>                 the bundle, e.g. build/release/Batuta.app
#   <identity>            a SHA-1 from `security find-identity`, or "-" for ad hoc
#   <entitlements>        the main executable's entitlements file
#   <inner executable>    a path relative to the bundle, e.g. Contents/MacOS/batuta-mcp
#
#   SIGN_TIMESTAMP=none   skip the secure timestamp (offline debug builds); ad hoc
#                         signatures never carry one, since they cannot
#
# What it does, after Apple's "Creating distribution-signed code for macOS":
#   - signs from the inside out and never with `--deep`, which would give every inner
#     executable the app's entitlements;
#   - gives every executable the Hardened Runtime (`--options runtime`) and a secure
#     timestamp, both of which notarization requires;
#   - gives inner executables no entitlements and a code-signing identifier of
#     `<bundle id>.<name>`, as Apple asks for nonbundled code;
#   - refuses an inner executable that is not Mach-O, and a Mach-O file anywhere in the
#     bundle that is neither the main executable nor listed: unsigned code inside a bundle
#     fails notarization, and finding it here is cheaper than finding it there.
#
# Anything else is a resource and is sealed as data, never signed: a script, or the Linux
# client's ELF binary in Contents/Resources ("executable code means a Mach-O image",
# Apple's "Placing content in a bundle").
#
# Identities are passed by SHA-1, not by name: on macOS 27 a name with a non-ASCII letter
# reaches codesign mis-encoded and matches no identity.
set -euo pipefail

fail() { echo "✗ $1" >&2; exit 1; }

[ $# -ge 3 ] || fail "usage: sign-bundle.sh <app> <identity> <entitlements> [<inner executable>...]"
APP="${1%/}"
IDENTITY="$2"
ENTITLEMENTS="$3"
shift 3
HELPERS=("$@")

test -d "$APP" || fail "no bundle at $APP"
test -f "$ENTITLEMENTS" || fail "no entitlements file at $ENTITLEMENTS"
PLIST="$APP/Contents/Info.plist"
test -f "$PLIST" || fail "no Info.plist in $APP"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")"
MAIN="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST")"

is_macho() {
  case "$(file -b "$1")" in *Mach-O*) return 0 ;; *) return 1 ;; esac
}

test -f "$APP/Contents/MacOS/$MAIN" || fail "the main executable $MAIN is missing"

# Every listed inner executable exists and is Mach-O.
for helper in ${HELPERS[@]+"${HELPERS[@]}"}; do
  test -f "$APP/$helper" || fail "inner executable $helper is missing"
  is_macho "$APP/$helper" \
    || fail "$helper is not a Mach-O image: it is a resource, sealed as data — do not list it"
done

# And every Mach-O file in the bundle is either the main executable or listed. Captured
# in a variable, not piped into a loop that exits early: under pipefail an early exit
# turns into SIGPIPE on `find` and a false result.
ALL_FILES="$(find "$APP/Contents" -type f -not -path '*/_CodeSignature/*')"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  relative="${path#"$APP"/}"
  [ "$relative" = "Contents/MacOS/$MAIN" ] && continue
  is_macho "$path" || continue
  listed=no
  for helper in ${HELPERS[@]+"${HELPERS[@]}"}; do
    [ "$helper" = "$relative" ] && listed=yes
  done
  [ "$listed" = yes ] || fail "$relative is Mach-O code and is not listed: it would ship unsigned"
done <<<"$ALL_FILES"

COMMON=(--force --options runtime)
if [ "$IDENTITY" = "-" ] || [ "${SIGN_TIMESTAMP:-secure}" = "none" ]; then
  COMMON+=(--timestamp=none)
else
  COMMON+=(--timestamp)
fi

for helper in ${HELPERS[@]+"${HELPERS[@]}"}; do
  codesign "${COMMON[@]}" --identifier "$BUNDLE_ID.$(basename "$helper")" \
    --sign "$IDENTITY" "$APP/$helper" >&2
done
codesign "${COMMON[@]}" --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP" >&2

# `--deep` is right for verifying (Apple's notarization guide uses it), wrong for signing.
codesign --verify --deep --strict "$APP" >&2 || fail "the signed bundle does not verify"
echo "✓ signed $(basename "$APP"): ${#HELPERS[@]} inner executable(s), then the bundle" >&2
