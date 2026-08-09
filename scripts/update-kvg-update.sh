#!/usr/bin/env bash
# Re-vendor addons/kvg_update/kvg_update.gd from KVG_Standards.
#
# Godot has no dependency manager that can pin a git ref, so the shared update
# checker is copied in rather than declared as a dependency. This script makes
# refreshing it one command, and rewrites the pin comment so the copy always
# records which upstream commit it came from — an un-pinned vendored file is how
# silent drift starts.
#
# Usage:  scripts/update-kvg-update.sh [path-to-KVG_Standards-checkout]
set -euo pipefail

STANDARDS="${1:-../KVG_Standards}"
SRC="$STANDARDS/packages/godot/kvg_update/kvg_update.gd"
DEST="addons/kvg_update/kvg_update.gd"

if [ ! -f "$SRC" ]; then
  echo "error: no kvg_update.gd at $SRC" >&2
  echo "       pass the path to a KVG_Standards checkout as \$1" >&2
  exit 1
fi

SHA="$(git -C "$STANDARDS" rev-parse --short HEAD)"
if [ -n "$(git -C "$STANDARDS" status --porcelain)" ]; then
  echo "warning: $STANDARDS has uncommitted changes; $SHA may not describe" >&2
  echo "         what is actually being copied." >&2
fi

{
  printf '# VENDORED from gerp93/KVG_Standards — do not edit here.\n'
  printf '#   source: packages/godot/kvg_update/kvg_update.gd\n'
  printf '#   commit: %s\n' "$SHA"
  printf '# Godot has no dependency manager that can pin a git ref, so this is copied in\n'
  printf '# rather than pinned. Refresh it with scripts/update-kvg-update.sh and update\n'
  printf '# the commit above; fix bugs upstream in KVG_Standards, not in this copy.\n\n'
  cat "$SRC"
} > "$DEST"

echo "re-vendored $DEST from $STANDARDS @ $SHA"
