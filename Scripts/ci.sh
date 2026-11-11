#!/bin/bash
#
# Ámbar's CI gate: the checks that need a Mac but no signing identity.
#
#   Scripts/ci.sh
#
# One script, three callers, so they cannot drift:
#   - a developer before merging, in the monorepo (native/);
#   - the public repository's GitHub workflow (public/github-workflows/ci.yml),
#     which export-public.sh copies to github.com/rrios-dev/ambar;
#   - Forgejo, if a macOS runner is ever registered there.
# Release-only checks (Developer ID, notarization) stay in release.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

step() { printf '\n▸ %s\n' "$*"; }

step "toolchain"
swift --version
xcodebuild -version

# Zero warnings after a forced rebuild: with a warm cache, swift build does not
# re-emit warnings for unchanged files and would report a meaningless 0.
step "build with zero warnings (forced rebuild)"
# Only this package's sources: a nested package (one with its own Package.swift) builds
# and checks itself. Named by shape, not by name, because this script is also exported.
EXCLUDE=()
while IFS= read -r dir; do EXCLUDE+=(-not -path "$dir/*"); done \
  < <(find . -mindepth 2 -maxdepth 2 -name Package.swift -not -path './.build/*' -exec dirname {} \;)
find . -name '*.swift' -not -path './.build/*' ${EXCLUDE[@]+"${EXCLUDE[@]}"} -exec touch {} +
OUT="$(swift build --build-tests 2>&1)" || { printf '%s\n' "$OUT" | tail -40 >&2; exit 1; }
COUNT="$(printf '%s' "$OUT" | grep -c 'warning:' || true)"
if [ "$COUNT" -ne 0 ]; then
  printf '%s' "$OUT" | grep 'warning:' | sort -u >&2
  echo "✗ $COUNT warning(s)" >&2
  exit 1
fi
echo "✓ 0 warnings"

# Hosted runners have no on-device speech models: those tests are skipped by a
# declared flag, never silently. Locally they always run. The tests check the
# variable's PRESENCE, so it is exported only on a CI runner, never as "".
step "tests"
if [ -n "${CI:-}" ]; then export AMBAR_SKIP_SPEECH_TESTS=1; fi
swift test

step "localization parity"
./Scripts/check-localization.sh

# The release chain's own tests, on a throwaway bundle signed ad hoc: no identity needed.
step "release chain"
./Scripts/release-chain.test.sh

echo
echo "✓ ci.sh: all checks passed"
