#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/player-created-world"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
LOG_DIR="$ARTIFACTS_DIR/test-logs"
RESULTS_DIR="$ARTIFACTS_DIR/test-results"

MODE="${1:-all}"
case "$MODE" in
  unit) MODE_FLAG="--unit" ;;
  integration) MODE_FLAG="--integration" ;;
  all) MODE_FLAG="--all" ;;
  *) echo "Usage: $0 [unit|integration|all]"; exit 2 ;;
esac

GODOT_BIN="${GODOT_BIN:-}"
if [[ -z "$GODOT_BIN" ]]; then
  if command -v godot4 >/dev/null 2>&1; then
    GODOT_BIN="$(command -v godot4)"
  elif command -v godot >/dev/null 2>&1; then
    GODOT_BIN="$(command -v godot)"
  elif [[ -x "$ROOT_DIR/godot/Godot_v4.6-stable_linux.x86_64" ]]; then
    GODOT_BIN="$ROOT_DIR/godot/Godot_v4.6-stable_linux.x86_64"
  else
    echo "GODOT_BIN not set and no Godot binary found."
    exit 1
  fi
fi

mkdir -p "$LOG_DIR" "$RESULTS_DIR"

"$GODOT_BIN" --headless --path "$PROJECT_DIR" --editor --quit

"$GODOT_BIN" --headless --path "$PROJECT_DIR" \
  --script "res://addons/gdUnit4/bin/GdUnitRunner.gd" -- \
  "$MODE_FLAG" \
  --junit="res://artifacts/test-results/junit.xml"
