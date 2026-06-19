#!/usr/bin/env bash
#
# Install the archon-bmad workflows into Archon.
#
# Copies every workflow in workflows/ into your Archon workflows directory.
#
#   ./install.sh                       # -> $ARCHON_HOME/workflows (default ~/.archon/workflows), global
#   ./install.sh /path/to/repo/.archon/workflows   # -> a specific project
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/workflows"

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: $SRC_DIR not found." >&2
  exit 1
fi

shopt -s nullglob
WORKFLOWS=("$SRC_DIR"/*.yaml "$SRC_DIR"/*.yml)
shopt -u nullglob

if [ ${#WORKFLOWS[@]} -eq 0 ]; then
  echo "ERROR: no workflow files (*.yaml) found in $SRC_DIR." >&2
  exit 1
fi

DEFAULT_DEST="${ARCHON_HOME:-$HOME/.archon}/workflows"
DEST="${1:-$DEFAULT_DEST}"

mkdir -p "$DEST"

echo "Installing ${#WORKFLOWS[@]} workflow(s) -> $DEST"
for wf in "${WORKFLOWS[@]}"; do
  cp "$wf" "$DEST/"
  echo "  + $(basename "$wf")"
done

echo
echo "Verify:   archon workflow list | grep archon-bmad"
echo "Run:      archon workflow run archon-bmad-story-automator \"epic 2\""
