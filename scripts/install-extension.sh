#!/usr/bin/env bash
# Installs Perch's editor extension, which is what lets a jump land on the right terminal
# tab instead of just the right window.
#
#   ./scripts/install-extension.sh            # every editor found
#   ./scripts/install-extension.sh --remove
#
# The extension is plain JavaScript with no dependencies, so installing it is a copy into
# the editor's extensions folder — no `vsce`, no packaging, no npm. VS Code, Cursor and
# Windsurf each run their own extension host, so each needs its own copy.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="$PERCH_ROOT/apps/vscode"
NAME="kweli.perch-jump-0.1.0"

# Editor → extensions directory.
EDITORS=(
  "VS Code:$HOME/.vscode/extensions"
  "VS Code Insiders:$HOME/.vscode-insiders/extensions"
  "Cursor:$HOME/.cursor/extensions"
  "Windsurf:$HOME/.windsurf/extensions"
)

MODE="${1:-install}"
FOUND=0

for entry in "${EDITORS[@]}"; do
  editor="${entry%%:*}"
  dir="${entry#*:}"
  # Only touch editors that are actually installed — creating the folder would make an
  # editor appear configured when it is not even there.
  [ -d "$dir" ] || continue
  FOUND=1
  target="$dir/$NAME"

  if [ "$MODE" = "--remove" ]; then
    if [ -d "$target" ]; then
      rm -rf "$target"
      ok "removed from $editor"
    else
      info "not installed in $editor"
    fi
    continue
  fi

  mkdir -p "$target"
  cp "$SRC/package.json" "$SRC/extension.js" "$target/"
  ok "installed into $editor"
done

if [ "$FOUND" -eq 0 ]; then
  warn "no supported editor found (VS Code, Cursor, Windsurf)"
  exit 0
fi

[ "$MODE" = "--remove" ] && exit 0

warn "restart the editor — extensions are loaded at startup"
info "then clicking a session card running in that editor focuses its terminal tab"
