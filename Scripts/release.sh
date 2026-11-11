#!/bin/bash
#
# The release chain for a macOS app under native/: preflight → Developer ID signature →
# notarization → staple → the check Gatekeeper runs. Ámbar's by default; another app
# (Batuta) passes its own bundle through the RELEASE_* variables below, from a thin
# wrapper in its own Scripts/.
#
# WHY IT EXISTS
#
# All of this used to live only as prose (`docs/initiatives/ambar/lanzamiento.md`). An
# independent audit pointed out that the chain was written down and had never been run,
# so nobody knew whether it was right or where exactly it would fail. A procedure nobody
# has run is an intention, not a procedure.
#
# What this script changes: the half that needs no credentials — the preflight — runs
# today, on every change if need be, and fails with a concrete reason. The half that does
# need them stays one command away, with its requirements checked BEFORE it starts rather
# than halfway through an upload to Apple's servers.
#
# USAGE
#
#   Scripts/release.sh preflight     check everything that needs no Apple account
#   Scripts/release.sh full          preflight + sign + notarize + staple + verify
#   Scripts/release.sh dmg           build the installer, notarize it and staple it
#
# `dmg` comes AFTER `full`, not inside it: the .app and the image are two artefacts and
# Gatekeeper judges them separately, so they are notarized in two submissions. Chaining
# them would hide that fact and force both to be repeated when one fails.
#
# `full` and `dmg` need, as environment variables:
#
#   DEVELOPER_ID   e.g. "Developer ID Application: Name (TEAMID)", or its SHA-1. May be
#                  left out: the one Developer ID Application identity in the keychain is
#                  used, and the run stops if there is none or more than one.
#   NOTARY_PROFILE the profile stored with `xcrun notarytool store-credentials`; no secret
#                  ever passes through this script.
#
# THE APP IT HANDLES (every variable defaults to Ámbar's value)
#
#   RELEASE_APP                    the bundle                    .build/Ambar.app
#   RELEASE_OUT_DIR                where the zip and DMG go      the bundle's folder
#   RELEASE_BUNDLE_ID              the identifier it must have   dev.rrios.ambar
#   RELEASE_ENTITLEMENTS           the main executable's         apps/Ambar/Ambar.entitlements
#   RELEASE_HELPERS                inner executables, relative   Contents/MacOS/ambar-mcp
#                                  to the bundle, signed first
#   RELEASE_REQUIRED_ENTITLEMENTS  keys that must be signed in   …device.audio-input
#   RELEASE_PLIST_KEYS             Info.plist keys required      version, copyright, microphone…
#   RELEASE_FORBIDDEN_STRINGS      a prefix only debug builds    AMBAR_
#                                  carry (review variables)
#   RELEASE_RESOURCE_BUNDLES       SwiftPM resource bundles      Ambar_Ambar Ambar_AppCore
#   RELEASE_LANGUAGES              their .lproj folders          es en fr de it pt-br ja zh-hans ko ru
#   RELEASE_SYSTEM_LANGUAGES       InfoPlist.strings languages   es en fr de it pt-BR ja zh-Hans ko ru
#   RELEASE_ICON                   the icon in Resources         AppIcon.icns ("" = warn only)
#   RELEASE_EXTRA_CHECK            an app's own check, a script  Scripts/check-doc-citations.sh
#   RELEASE_VOLUME_NAME            the DMG's volume (make-dmg)   Ámbar
#   RELEASE_DMG_BACKGROUND         its background generator      Scripts/make-dmg-background.swift
#
# A variable set to "" means "none" (no inner executables, no extra check, no icon
# required); unset means Ámbar's value. Lists are space-separated.
#
# Anything in the bundle that is not Mach-O — a script, the Linux client's ELF binary in
# Contents/Resources — is a resource: sealed as data, never signed (sign-bundle.sh).
#
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
MODE="${1:-preflight}"

APP="${RELEASE_APP:-$ROOT/.build/Ambar.app}"
APP="${APP%/}"
OUT_DIR="${RELEASE_OUT_DIR:-$(dirname "$APP")}"
BUNDLE_ID="${RELEASE_BUNDLE_ID:-dev.rrios.ambar}"
ENTITLEMENTS="${RELEASE_ENTITLEMENTS:-$ROOT/apps/Ambar/Ambar.entitlements}"
HELPERS="${RELEASE_HELPERS-Contents/MacOS/ambar-mcp}"
REQUIRED_ENTITLEMENTS="${RELEASE_REQUIRED_ENTITLEMENTS-com.apple.security.device.audio-input}"
PLIST_KEYS="${RELEASE_PLIST_KEYS-CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion NSHumanReadableCopyright NSMicrophoneUsageDescription}"
FORBIDDEN_STRINGS="${RELEASE_FORBIDDEN_STRINGS-AMBAR_}"
RESOURCE_BUNDLES="${RELEASE_RESOURCE_BUNDLES-Ambar_Ambar Ambar_AppCore}"
LANGUAGES="${RELEASE_LANGUAGES-es en fr de it pt-br ja zh-hans ko ru}"
SYSTEM_LANGUAGES="${RELEASE_SYSTEM_LANGUAGES-es en fr de it pt-BR ja zh-Hans ko ru}"
ICON="${RELEASE_ICON-AppIcon.icns}"
EXTRA_CHECK="${RELEASE_EXTRA_CHECK-$SCRIPTS/check-doc-citations.sh}"
export RELEASE_APP="$APP" RELEASE_OUT_DIR="$OUT_DIR"

NAME="$(basename "$APP" .app)"
PLIST="$APP/Contents/Info.plist"
read -r -a HELPER_LIST <<<"$HELPERS"

fail() { echo "✗ $1" >&2; exit 1; }
ok()   { echo "✓ $1"; }
# How messages name an executable: the bundle by its name, an inner one by its path in it.
label() { if [ "$1" = "$APP" ]; then echo "$NAME.app"; else echo "${1#"$APP"/}"; fi; }

# Whether a `codesign -d --verbose=4` output shows <what>: "runtime" is read from the
# CodeDirectory's flags, anything else must start a line ("Timestamp=", "Authority=…").
# Never a bare substring match: the output names the file's path, and a path with
# "runtime" in it made a bundle without the Hardened Runtime pass (release-chain.test.sh).
signature_has() {
  local info="$1" what="$2" flags
  if [ "$what" = runtime ]; then
    flags="$(sed -n 's/^CodeDirectory .*flags=0x[0-9a-fA-F]*(\([^)]*\)).*/\1/p' <<<"$info")"
    case ",$flags," in *,runtime,*) return 0 ;; *) return 1 ;; esac
  fi
  case $'\n'"$info" in *$'\n'"$what"*) return 0 ;; *) return 1 ;; esac
}

# `codesign -d` right after a --force signature can read the previous, cached signature
# (measured on Ámbar: one false negative in three runs), so it is read until it shows
# what is asked for, five times at most. Captured into a variable, never piped into
# `grep -q`: under `pipefail` grep exits at its first match, codesign gets SIGPIPE and the
# pipeline fails exactly when the check succeeds. That trap has bitten this repository at
# least four times.
signature_info() {
  local target="$1" wanted="$2" info=""
  for _ in 1 2 3 4 5; do
    info="$(codesign -d --verbose=4 "$target" 2>&1 || true)"
    signature_has "$info" "$wanted" && break
    sleep 0.4
  done
  printf '%s' "$info"
}

# The top-level keys of an entitlements plist, sorted, one per line.
entitlement_keys() {
  plutil -p - 2>/dev/null | sed -n 's/^  "\([^"]*\)" =>.*/\1/p' | sort
}

# ---------------------------------------------------------------------------
# Preflight — everything that can be checked without an Apple account.
# ---------------------------------------------------------------------------

preflight() {
  echo "▸ Release preflight: $NAME"

  test -d "$APP" || fail "no bundle at $APP — build it first (make-app.sh release)"
  test -f "$PLIST" || fail "no Info.plist in $APP"
  local main
  main="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" 2>/dev/null || true)"
  test -n "$main" && test -f "$APP/Contents/MacOS/$main" || fail "the main executable is missing"
  local executables=("$APP")
  for helper in ${HELPER_LIST[@]+"${HELPER_LIST[@]}"}; do
    test -f "$APP/$helper" || fail "inner executable $helper is missing"
    executables+=("$APP/$helper")
  done

  # 1. Release binaries, not debug ones. A debug bundle signed and notarized is a failure
  #    only found when someone uses it: debug builds read review variables (Ámbar's
  #    AMBAR_DATA_DIR moves where the user's history lives). `strings` into a variable,
  #    not `| grep -q`, for the SIGPIPE reason above — the third time it bit here.
  if [ -n "$FORBIDDEN_STRINGS" ]; then
    local text binary
    for binary in "$APP/Contents/MacOS/$main" ${HELPER_LIST[@]+"${HELPER_LIST[@]/#/$APP/}"}; do
      text="$(strings "$binary" || true)"
      case "$text" in
        *"$FORBIDDEN_STRINGS"*)
          fail "$(basename "$binary") carries review variables ($FORBIDDEN_STRINGS*): not a release build" ;;
      esac
    done
    ok "release binaries, no review variables ($FORBIDDEN_STRINGS*)"
  fi

  # 2. Hardened Runtime on every executable. Without it notarization is refused — for
  #    the bundle, and for each inner executable on its own.
  local target info
  for target in "${executables[@]}"; do
    info="$(signature_info "$target" runtime)"
    signature_has "$info" runtime \
      || fail "no Hardened Runtime on $(label "$target"): Apple would refuse notarization"
  done
  ok "Hardened Runtime on all ${#executables[@]} executable(s)"

  # 3. The signature seals what is inside, nested code included, and satisfies its own
  #    designated requirement. `--deep` is right for verifying, wrong for signing.
  codesign --verify --deep --strict "$APP" 2>/dev/null || fail "the signature does not verify"
  ok "signature valid and sealed (--deep --strict)"

  # 4. Entitlements: exactly the declared ones on the app, none on inner executables, and
  #    none that loosens execution.
  local signed declared
  signed="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | entitlement_keys || true)"
  declared="$(entitlement_keys <"$ENTITLEMENTS" || true)"
  local dangerous
  for dangerous in \
      com.apple.security.cs.allow-jit \
      com.apple.security.cs.disable-library-validation \
      com.apple.security.cs.allow-unsigned-executable-memory \
      com.apple.security.cs.disable-executable-page-protection \
      com.apple.security.cs.allow-dyld-environment-variables \
      com.apple.security.cs.debugger \
      com.apple.security.get-task-allow; do
    case $'\n'"$signed"$'\n' in
      *$'\n'"$dangerous"$'\n'*) fail "an entitlement that loosens execution: $dangerous" ;;
    esac
  done
  local required
  for required in $REQUIRED_ENTITLEMENTS; do
    case $'\n'"$signed"$'\n' in
      *$'\n'"$required"$'\n'*) ;;
      *) fail "missing entitlement $required" ;;
    esac
  done
  [ "$signed" = "$declared" ] \
    || fail "the signed entitlements ($(echo $signed)) are not the declared ones ($(echo $declared))"
  for helper in ${HELPER_LIST[@]+"${HELPER_LIST[@]}"}; do
    [ -z "$(codesign -d --entitlements - --xml "$APP/$helper" 2>/dev/null | entitlement_keys || true)" ] \
      || fail "$helper carries entitlements: inner executables get none"
  done
  ok "entitlements: exactly the declared ones ($(echo $declared)), none dangerous"

  # 5. Metadata Apple requires, and which is only noticed when it is missing.
  local key id
  for key in $PLIST_KEYS; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 \
      || fail "$key is missing from Info.plist"
  done
  id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")"
  [ "$id" = "$BUNDLE_ID" ] || fail "unexpected bundle identifier: $id (expected $BUNDLE_ID)"
  ok "metadata complete: $(echo $PLIST_KEYS | wc -w | tr -d ' ') keys, identifier $id"

  # 6. Localized resources travel INSIDE the bundle — every resource bundle, not only
  #    the app's: Ámbar's AppCore carries the shortcut recorder's strings, and once a
  #    whole language could be deleted from it while this check said all ten travelled.
  #    Xcode 27's SwiftPM builds each resource bundle with the full macOS layout
  #    (`Contents/Resources/<lang>.lproj`); earlier versions left the folders at its root.
  #    Both are valid and `Bundle(url:)` reads either, so either passes.
  if [ -n "$RESOURCE_BUNDLES" ]; then
    local missing=0 root bundle lang
    for bundle in $RESOURCE_BUNDLES; do
      root="$APP/Contents/Resources/$bundle.bundle"
      test -d "$root" || { echo "  missing $bundle.bundle" >&2; missing=$((missing + 1)); continue; }
      [ -d "$root/Contents/Resources" ] && root="$root/Contents/Resources"
      for lang in $LANGUAGES; do
        test -d "$root/$lang.lproj" || {
          echo "  missing $lang in $bundle.bundle" >&2
          missing=$((missing + 1))
        }
      done
    done
    [ "$missing" -eq 0 ] || fail "$missing languages or bundles do not travel in the resource bundles"
    ok "the $(echo $LANGUAGES | wc -w | tr -d ' ') languages travel in the resource bundles ($RESOURCE_BUNDLES)"
  fi

  # 6.bis. And the SYSTEM dialogs' texts, which macOS does not read from there. Usage
  #    descriptions — the text shown when the system asks for the microphone — are read
  #    from the main bundle's `Contents/Resources/<lang>.lproj/`. An audit once broke the
  #    loop that copies them and this preflight passed a bundle whose dialog came out in
  #    one language for the whole planet.
  if [ -n "$SYSTEM_LANGUAGES" ]; then
    local without=0
    for lang in $SYSTEM_LANGUAGES; do
      test -f "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings" || without=$((without + 1))
    done
    [ "$without" -eq 0 ] \
      || fail "$without languages without InfoPlist.strings: the permission dialogs would come out untranslated"
    ok "the $(echo $SYSTEM_LANGUAGES | wc -w | tr -d ' ') system permission dialogs travel translated"
  fi

  # 7. The icon. Without it macOS paints a generic one and the app looks broken before it
  #    opens. An app whose icon is still to be chosen says so with RELEASE_ICON="".
  if [ -n "$ICON" ]; then
    test -f "$APP/Contents/Resources/$ICON" || fail "$ICON is missing"
    ok "icon present"
  else
    echo "  WARNING: no icon required for $NAME — macOS shows the generic one"
  fi

  # 8. Fallback language: what anyone who speaks none of the translated languages sees.
  local region
  region="$(plutil -extract CFBundleDevelopmentRegion raw "$PLIST" 2>/dev/null || echo "")"
  [ "$region" = "en" ] || fail "fallback language «${region}»: anyone outside the translated languages would see it"
  ok "fallback language is English"

  # 9. The app's own check (Ámbar: the documentation's citations of code resolve). Its
  #    output is not sent to /dev/null: the count it prints is what shows it looked.
  if [ -n "$EXTRA_CHECK" ]; then
    bash "$EXTRA_CHECK" || fail "the app's own check failed ($(basename "$EXTRA_CHECK"))"
    ok "$(basename "$EXTRA_CHECK") passed"
  fi

  echo "✓ Preflight passed: $NAME is ready to be signed with Developer ID"
}

# ---------------------------------------------------------------------------
# The chain with credentials.
# ---------------------------------------------------------------------------

require_credentials() {
  local identities
  identities="$(security find-identity -p codesigning -v 2>/dev/null || true)"
  if [ -z "${DEVELOPER_ID:-}" ]; then
    local found count
    found="$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<<"$identities" | sort -u || true)"
    count="$(grep -c . <<<"$found" || true)"
    [ "$count" = "1" ] && DEVELOPER_ID="$found"
    [ "$count" -gt 1 ] 2>/dev/null \
      && fail "several Developer ID identities in the keychain: set DEVELOPER_ID to one of them"
  fi

  # Checked BEFORE anything is touched: finding the profile missing halfway through an
  # upload leaves the bundle half signed and everything to start again.
  [ -n "${DEVELOPER_ID:-}" ] \
    || fail "DEVELOPER_ID is not set and the keychain has no Developer ID Application identity"
  [ -n "${NOTARY_PROFILE:-}" ] \
    || fail "NOTARY_PROFILE is not set — store one with: xcrun notarytool store-credentials"

  # Signed by SHA-1, not by name: on macOS 27 a name with a non-ASCII letter reaches
  # codesign mis-encoded and it finds no identity. DEVELOPER_ID keeps the name for the
  # messages; it may also be given as the SHA-1 itself.
  DEVELOPER_ID_HASH="$(awk -v name="\"$DEVELOPER_ID\"" 'index($0, name) { print $2; exit }' <<<"$identities")"
  [[ "$DEVELOPER_ID" =~ ^[0-9A-F]{40}$ ]] && DEVELOPER_ID_HASH="$DEVELOPER_ID"
  case "$identities" in
    *"$DEVELOPER_ID_HASH"*) : ;;
    *) DEVELOPER_ID_HASH="" ;;
  esac
  [ -n "$DEVELOPER_ID_HASH" ] || fail "the identity «${DEVELOPER_ID}» is not a valid one in the keychain"
  ok "credentials present"
}

# Submits a file and waits for the verdict. The log is kept and its status read: only
# "Accepted" passes (Quill's lesson — the exit code alone is not the verdict).
notarize() {
  local file="$1" log
  log="$OUT_DIR/notary-$(basename "$file").log"
  echo "▸ Notarizing $(basename "$file") (this takes a while; waiting for the verdict)"
  if ! xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait >"$log" 2>&1; then
    cat "$log" >&2
    fail "notarization failed — ask for the log with: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
  fi
  local verdict
  verdict="$(cat "$log")"
  case "$verdict" in
    *"status: Accepted"*) ;;
    *) cat "$log" >&2; fail "notarization did not return Accepted (log: $log)" ;;
  esac
  ok "$(basename "$file"): Accepted (log: $log)"
}

full_release() {
  preflight
  require_credentials

  echo "▸ Signing with Developer ID, inner executables first"
  # The local signature is replaced whole: every inner executable, then the bundle, each
  # with the Hardened Runtime and a secure timestamp (sign-bundle.sh).
  "$SCRIPTS/sign-bundle.sh" "$APP" "$DEVELOPER_ID_HASH" "$ENTITLEMENTS" \
    ${HELPER_LIST[@]+"${HELPER_LIST[@]}"} || fail "the Developer ID signature failed"
  local target info
  for target in "$APP" ${HELPER_LIST[@]+"${HELPER_LIST[@]/#/$APP/}"}; do
    info="$(signature_info "$target" "Timestamp=")"
    signature_has "$info" "Authority=Developer ID Application" \
      || fail "$(label "$target") is not signed with Developer ID"
    signature_has "$info" runtime || fail "$(label "$target") has no Hardened Runtime"
    signature_has "$info" "Timestamp=" || fail "$(label "$target") has no secure timestamp"
  done
  ok "signed and sealed: Developer ID, Hardened Runtime and secure timestamp on every executable"

  echo "▸ Packing for notarization"
  local zip="$OUT_DIR/$NAME.zip"
  mkdir -p "$OUT_DIR"
  rm -f "$zip"
  # `ditto -c -k --keepParent` is the packing Apple accepts: it keeps the extended
  # attributes and the bundle's structure.
  ditto -c -k --keepParent "$APP" "$zip"
  notarize "$zip"

  echo "▸ Stapling the ticket"
  # Without it, the app needs the network the first time it opens.
  xcrun stapler staple "$APP" || fail "could not staple the ticket"
  xcrun stapler validate "$APP" || fail "the stapled ticket does not validate"
  ok "ticket stapled and validated"

  echo "▸ Checking it as the user will"
  # `spctl` is what Gatekeeper runs the first time the app is opened.
  spctl --assess --type execute --verbose=4 "$APP" || fail "Gatekeeper would refuse the app"
  ok "Gatekeeper accepts it"

  rm -f "$zip"
  echo "✓ Release ready: $APP"
}

# ---------------------------------------------------------------------------
# The installer — the DMG the user downloads, notarized apart from the .app.
# ---------------------------------------------------------------------------

# The app that goes into the DMG is the one `full` left: Developer ID on every executable
# and its ticket stapled. A preflight or make-app run after `full` rebuilds the bundle
# signed but not notarized, and an image of that would open with a warning offline.
require_released_app() {
  test -d "$APP" || fail "no bundle at $APP — run \`full\` first"
  local target info
  for target in "$APP" ${HELPER_LIST[@]+"${HELPER_LIST[@]/#/$APP/}"}; do
    info="$(signature_info "$target" "Authority=Developer ID Application")"
    signature_has "$info" "Authority=Developer ID Application" \
      || fail "$(label "$target") is not signed with Developer ID — run \`full\` before \`dmg\`"
  done
  xcrun stapler validate "$APP" >/dev/null 2>&1 \
    || fail "$NAME.app carries no stapled ticket — run \`full\` before \`dmg\`"
  ok "the app is the released one: Developer ID and a stapled ticket"
}

dmg_release() {
  echo "▸ Installer (DMG): $NAME"
  require_released_app
  require_credentials

  # Building and checking the image lives in make-dmg.sh, which also signs it when given
  # the identity. Here it is only handed over and the result notarized.
  CODESIGN_IDENTITY="$DEVELOPER_ID_HASH" "$SCRIPTS/make-dmg.sh" || fail "building the DMG failed"

  local version dmg
  version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
  dmg="$OUT_DIR/$NAME-$version.dmg"
  test -f "$dmg" || fail "no DMG at $dmg"

  notarize "$dmg"

  echo "▸ Stapling the ticket to the DMG"
  # Without it, whoever opens the image offline sees the unidentified-developer warning
  # even though the app inside is notarized.
  xcrun stapler staple "$dmg" || fail "could not staple the ticket to the DMG"
  xcrun stapler validate "$dmg" || fail "the DMG's stapled ticket does not validate"
  ok "ticket stapled and validated"

  # `spctl` on the image is what Gatekeeper runs when it is opened, and it is a different
  # assessment from the app's: `open`, not `execute`.
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" \
    || fail "Gatekeeper would refuse the DMG"
  ok "Gatekeeper accepts the DMG"

  # The checksum the download page or release notes print next to the file.
  (cd "$OUT_DIR" && shasum -a 256 "$(basename "$dmg")" >"$(basename "$dmg").sha256")
  ok "SHA-256: $(cut -d' ' -f1 "$dmg.sha256")"

  echo "✓ Installer ready: $dmg"
}

case "$MODE" in
  preflight) preflight ;;
  dmg)       dmg_release ;;
  full)      full_release ;;
  *)         fail "unknown mode «${MODE}» — use: preflight | full | dmg" ;;
esac
