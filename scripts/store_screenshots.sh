#!/usr/bin/env bash
#
# Regenerates the store screenshot decks in store_screenshots/ from the
# current app:
#   1. test/screenshot_test.dart with EDITOR_CAPTURES=true renders the six
#      store scenes bare (phone 1100x2390 + desktop 3840x2400, light + dark)
#      into the gitignored screenshots/editor/<locale>/.
#   2. store_screenshots/scripts/sync-captures.mjs copies them into the
#      editor's public/screenshots/.
#   3. store_screenshots/scripts/export.mjs exports every deck headless into
#      store_screenshots/out/<platform>/<device>/<WxH>/<locale>/.
#
# The decks themselves (copy, layouts, placement) live in
# store_screenshots/app-store-screenshots.json; edit them in the editor:
#   cd store_screenshots && bun dev
#
# Usage: scripts/store_screenshots.sh [--locales en,de] [--no-capture] [--no-export] [deck ...]
#   --no-capture  reuse the existing screenshots/editor/ captures
#   --no-export   stop after syncing (e.g. to open the editor)
#   deck          iphone android mac android-10 android-7 feature-graphic (default: all)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDITOR="$ROOT/store_screenshots"
LOCALES=en
CAPTURE=1
EXPORT=1
DECKS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --locales) LOCALES="$2"; shift 2 ;;
    --no-capture) CAPTURE=0; shift ;;
    --no-export) EXPORT=0; shift ;;
    *) DECKS+=("$1"); shift ;;
  esac
done

if [ "$CAPTURE" = 1 ]; then
  echo "==> Rendering editor captures ($LOCALES)"
  rm -rf "$ROOT/screenshots/editor"
  (cd "$ROOT" && flutter test --run-skipped --update-goldens \
    --dart-define=EDITOR_CAPTURES=true --dart-define=STORE_LOCALES="$LOCALES" \
    --name '^(Device|Trainer|Customization|Trainer Controls|Devices|Virtual Shifting Settings)$' \
    test/screenshot_test.dart)
fi

[ -d "$EDITOR/node_modules" ] || (cd "$EDITOR" && bun install)

echo "==> Syncing captures into the editor"
(cd "$EDITOR" && node scripts/sync-captures.mjs)

if [ "$EXPORT" = 1 ]; then
  echo "==> Exporting decks"
  (cd "$EDITOR" && node scripts/export.mjs ${DECKS[@]+"${DECKS[@]}"})
fi
