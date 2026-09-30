#!/bin/bash
#
# Exports Ámbar's public repository (github.com/rrios-dev/ambar) from this directory.
#
# The monorepo stays the source of truth; the public repository receives one snapshot per
# release on its own history. This copies what the app is made of and nothing else: not the
# other native projects that share `native/`, not the build output, not the documents about
# the web that used to sell it.
#
# Usage: Scripts/export-public.sh <destination>   (the destination's .git is left alone)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:?usage: export-public.sh <destination>}"
mkdir -p "$DEST"

# Everything tracked under native/, minus what is not Ámbar or not meant to be public.
find "$DEST" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
( cd "$ROOT" && git ls-files -z . ) | while IFS= read -r -d '' file; do
  case "$file" in
    argos/*|public/*) continue ;;
  esac
  mkdir -p "$DEST/$(dirname "$file")"
  cp -p "$ROOT/$file" "$DEST/$file"
done

# The development guide keeps its Spanish; the front page speaks to anyone.
mkdir -p "$DEST/docs" "$DEST/.github/workflows"
mv "$DEST/README.md" "$DEST/docs/development.md"
cp "$ROOT/public/README.md" "$DEST/README.md"
cp "$ROOT/public/gitignore" "$DEST/.gitignore"
cp "$ROOT/public/github-workflows/ci.yml" "$DEST/.github/workflows/ci.yml"
for doc in ambar-dictado.md ambar-icono.md; do
  cp "$ROOT/../docs/$doc" "$DEST/docs/$doc"
done
sips -s format png "$ROOT/apps/Ambar/Resources/AppIcon.icns" --resampleWidth 256 \
  --out "$DEST/docs/icon.png" >/dev/null

echo "exported to $DEST"
