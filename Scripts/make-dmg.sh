#!/bin/bash
#
# Packs a macOS app into a disk image with drag-to-Applications. Ámbar's by default;
# another app passes its bundle through the RELEASE_* variables release.sh documents.
#
# WHY IT EXISTS
#
# The release chain produced a signed, notarized `.app` and stopped there: packing lived
# as four lines of prose in `docs/initiatives/ambar/lanzamiento.md` that nobody had run.
# The same defect `release.sh` came to fix for signing — a procedure nobody has run is an
# intention, not a procedure — left for the last stretch: what the user downloads and opens.
#
# WHAT IT PRODUCES
#
#   <RELEASE_OUT_DIR>/<Name>-<version>.dmg   compressed, with the .app and an alias to /Applications
#
# The DMG is notarized APART from the .app: two artefacts, judged separately by
# Gatekeeper. See `release.sh dmg`, which does both in order.
#
# USAGE
#
#   Scripts/make-dmg.sh                  # unsigned image (or with the local identity)
#   CODESIGN_IDENTITY="Developer ID Application: …" Scripts/make-dmg.sh
#
#   RELEASE_APP             the bundle                  .build/Ambar.app
#   RELEASE_OUT_DIR         where the image goes        the bundle's folder
#   RELEASE_VOLUME_NAME     the mounted volume's name   Ámbar
#   RELEASE_DMG_BACKGROUND  a Swift script that draws   Scripts/make-dmg-background.swift
#                           the window's background ("" = none)
#
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
APP="${RELEASE_APP:-$ROOT/.build/Ambar.app}"
APP="${APP%/}"
BUILD="${RELEASE_OUT_DIR:-$(dirname "$APP")}"
VOLUME_NAME="${RELEASE_VOLUME_NAME:-Ámbar}"
BACKGROUND="${RELEASE_DMG_BACKGROUND-$SCRIPTS/make-dmg-background.swift}"
APP_NAME="$(basename "$APP")"
NAME="${APP_NAME%.app}"

fail() { echo "✗ $1" >&2; exit 1; }
ok()   { echo "✓ $1"; }

# ---------------------------------------------------------------------------
# 1. What is packed must be releasable
# ---------------------------------------------------------------------------

test -d "$APP" || fail "no bundle at $APP — build it first (make-app.sh release)"

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || true)"
test -n "$VERSION" || fail "the bundle declares no CFBundleShortVersionString"

# Hardened Runtime: without it the DMG would carry something notarization refuses, found
# out after the upload. Read into a variable, never piped into `grep -q` (under pipefail,
# grep closes the pipe at its first match, codesign gets SIGPIPE and the check is false
# exactly when it finds what it looks for), and retried, because a `codesign -d` right
# after signing can read the previous, cached signature (measured: one run in three).
# The flag is read from the CodeDirectory's flags, not anywhere in the output: the output
# names the bundle's path, and a path holding "runtime" would pass without the flag.
SIGN_FLAGS=""
for _ in 1 2 3 4 5; do
  SIGN_INFO="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
  SIGN_FLAGS="$(sed -n 's/^CodeDirectory .*flags=0x[0-9a-fA-F]*(\([^)]*\)).*/\1/p' <<<"$SIGN_INFO")"
  case ",$SIGN_FLAGS," in
    *,runtime,*) break ;;
  esac
  sleep 0.4
done
case ",$SIGN_FLAGS," in
  *,runtime,*) ok "the bundle carries the Hardened Runtime" ;;
  *) fail "the bundle has no Hardened Runtime: it could not be notarized inside the DMG" ;;
esac

mkdir -p "$BUILD"
DMG="$BUILD/$NAME-$VERSION.dmg"
STAGE="$BUILD/dmg-stage"
TEMP_DMG="$BUILD/$NAME-$VERSION-rw.dmg"
MOUNT_POINT=""

# ---------------------------------------------------------------------------
# Cleanup: a hung mount locks the file and the next attempt fails with a "resource busy"
# that says nothing about the cause.
# ---------------------------------------------------------------------------

detach_quietly() {
  local point="$1"
  [ -n "$point" ] || return 0
  [ -d "$point" ] || return 0
  for _ in 1 2 3 4 5; do
    if hdiutil detach "$point" -quiet 2>/dev/null; then return 0; fi
    sleep 1
  done
  hdiutil detach "$point" -force -quiet 2>/dev/null || true
}

cleanup() {
  detach_quietly "$MOUNT_POINT"
  rm -rf "$STAGE"
  rm -f "$TEMP_DMG"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 2. The image's content
# ---------------------------------------------------------------------------

rm -rf "$STAGE"
mkdir -p "$STAGE"

# `ditto`, not `cp -R`: it keeps the extended attributes and the bundle's structure, which
# is what keeps the signature valid inside the image.
ditto "$APP" "$STAGE/$APP_NAME"

# The alias to Applications is what makes the image an installer: dragging from one icon
# to the other is the gesture everyone on macOS already knows.
ln -s /Applications "$STAGE/Applications"

HAS_BACKGROUND="no"
if [ -n "$BACKGROUND" ]; then
  mkdir -p "$STAGE/.background"
  swift "$BACKGROUND" "$STAGE/.background/background.png" \
    || fail "could not draw the window's background"
  HAS_BACKGROUND="yes"
fi

ok "content ready: $APP_NAME $VERSION + alias to /Applications"

# ---------------------------------------------------------------------------
# 3. A read/write image, so the window can be laid out
# ---------------------------------------------------------------------------

rm -f "$TEMP_DMG"
# HFS+, not APFS: an APFS image does not open on older macOS, and the message whoever
# tries sees does not say why. The image's file system has nothing to do with the app's
# minimum macOS.
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME_NAME" -fs HFS+ \
  -format UDRW -ov -quiet "$TEMP_DMG" \
  || fail "hdiutil could not create the working image"

MOUNT_POINT="/Volumes/$VOLUME_NAME"
# `-nobrowse` so it does not show in the sidebar while it is laid out.
hdiutil attach "$TEMP_DMG" -nobrowse -quiet || fail "could not mount the working image"

# ---------------------------------------------------------------------------
# 4. The window — cosmetic, and therefore not blocking
# ---------------------------------------------------------------------------
#
# Placing icons and setting the background can only be asked of the Finder through
# AppleScript, which needs the Automation permission: in CI, or a session without it,
# `osascript` fails with -1743. That failure does NOT invalidate the DMG — it still holds
# the app and the alias, which is what installing needs — so it warns and goes on. What
# it does not do is pretend it worked.
#
# The coordinates are computed against the background's size (620×400 in
# `make-dmg-background.swift`): if one changes, so must the other.

LAYOUT_APPLIED="no"
if osascript - "$VOLUME_NAME" "$APP_NAME" "$HAS_BACKGROUND" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set volumeName to item 1 of argv
  set appName to item 2 of argv
  set hasBackground to item 3 of argv
  tell application "Finder"
    tell disk volumeName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 160, 820, 560}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 96
      if hasBackground is "yes" then
        set background picture of viewOptions to file ".background:background.png"
      end if
      set position of item appName of container window to {170, 170}
      set position of item "Applications" of container window to {450, 170}
      close
      open
      update without registering applications
      delay 1
    end tell
  end tell
end run
APPLESCRIPT
then
  LAYOUT_APPLIED="yes"
  ok "window laid out: icons at 96 px, toolbar hidden, background: $HAS_BACKGROUND"
else
  echo "  WARNING: the window could not be laid out (the Finder needs the Automation"
  echo "  permission, and CI has none). The DMG is valid all the same: it holds"
  echo "  $APP_NAME and the alias to /Applications, without positions or background."
fi

sync
detach_quietly "$MOUNT_POINT"
MOUNT_POINT=""

# ---------------------------------------------------------------------------
# 5. Compress
# ---------------------------------------------------------------------------

rm -f "$DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$DMG" \
  || fail "could not compress the image"
rm -f "$TEMP_DMG"
ok "image compressed: $(du -h "$DMG" | cut -f1)"

# ---------------------------------------------------------------------------
# 6. Sign the image, when there is something to sign it with
# ---------------------------------------------------------------------------
#
# The DMG is signed IN ADDITION to the .app. Unsigned, Gatekeeper warns when the image is
# opened even though the app inside is notarized, and the user sees the warning first.

IDENTITY="${CODESIGN_IDENTITY:-${DEVELOPER_ID:-}}"
# By SHA-1 when given a name: on macOS 27 a name with a non-ASCII letter reaches codesign
# mis-encoded and it finds no identity.
if [ -n "$IDENTITY" ] && ! [[ "$IDENTITY" =~ ^[0-9A-F]{40}$ ]]; then
  KEYCHAIN_IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
  HASH="$(awk -v name="\"$IDENTITY\"" 'index($0, name) { print $2; exit }' <<<"$KEYCHAIN_IDENTITIES")"
  [ -n "$HASH" ] && IDENTITY="$HASH"
fi
if [ -n "$IDENTITY" ]; then
  # `--timestamp` because notarization requires a secure one. With an ad hoc identity it
  # would fail, which is why the image is signed only when a real identity is declared.
  codesign --force --sign "$IDENTITY" --timestamp "$DMG" \
    || fail "could not sign the DMG with «$IDENTITY»"
  codesign --verify --strict "$DMG" || fail "the DMG's signature does not verify"
  ok "DMG signed with «$IDENTITY»"
else
  echo "  WARNING: unsigned DMG. Releasing it needs"
  echo "  CODESIGN_IDENTITY=\"Developer ID Application: …\" and notarizing it afterwards."
fi

# ---------------------------------------------------------------------------
# 7. Check the result by mounting it, as the user will
# ---------------------------------------------------------------------------
#
# Check the file produced, not the process that produced it: a DMG created without errors
# can still hold a broken alias or a bundle missing something.

# The mount point lives in the system's temporary folder and NOT inside the build folder:
# measured, mounting at a point on another volume — the repository is on an external
# disk — fails with an expected CRC and an `attach` that never completes, and the message
# says nothing about volumes. In the temporary folder it mounts the first time.
VERIFY_POINT="$(mktemp -d "${TMPDIR:-/tmp}/$NAME-dmg-verify.XXXXXX")"
hdiutil attach "$DMG" -nobrowse -readonly -quiet -mountpoint "$VERIFY_POINT" \
  || fail "the DMG produced cannot be mounted"
MOUNT_POINT="$VERIFY_POINT"

test -d "$VERIFY_POINT/$APP_NAME" || fail "the DMG does not contain $APP_NAME"
test -L "$VERIFY_POINT/Applications" || fail "the DMG does not contain the alias to Applications"
LINK_TARGET="$(readlink "$VERIFY_POINT/Applications")"
[ "$LINK_TARGET" = "/Applications" ] \
  || fail "the alias points to «$LINK_TARGET» instead of /Applications"

# The app's signature must still verify INSIDE the image, nested code included: if packing
# had touched one byte of the bundle, this is the only thing that would notice.
codesign --verify --deep --strict "$VERIFY_POINT/$APP_NAME" \
  || fail "the bundle's signature does not verify inside the DMG"

if [ "$HAS_BACKGROUND" = "yes" ]; then
  test -f "$VERIFY_POINT/.background/background.png" || fail "the background did not travel in the DMG"
fi

detach_quietly "$VERIFY_POINT"
MOUNT_POINT=""
rmdir "$VERIFY_POINT" 2>/dev/null || true

ok "checked by mounting it: app, alias, signature$([ "$HAS_BACKGROUND" = yes ] && echo ' and background')"
echo
echo "▸ $DMG"
echo "  window laid out: $LAYOUT_APPLIED"
echo
echo "  Next step to release it:"
echo "    xcrun notarytool submit \"$DMG\" --keychain-profile \"${NOTARY_PROFILE:-<profile>}\" --wait"
echo "    xcrun stapler staple \"$DMG\""
