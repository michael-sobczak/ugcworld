#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/player-created-world"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
LOG_DIR="$ARTIFACTS_DIR/test-logs"
RESULTS_DIR="$ARTIFACTS_DIR/test-results"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse --show-results flag from any position in the argument list.
SHOW_RESULTS=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --show-results) SHOW_RESULTS=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

MODE="${POSITIONAL[0]:-all}"
EVAL_MODEL="${POSITIONAL[1]:-}"
case "$MODE" in
  unit) MODE_FLAG="--unit" ;;
  integration) MODE_FLAG="--integration" ;;
  eval) MODE_FLAG="--eval" ;;
  all) MODE_FLAG="--all" ;;
  *) echo "Usage: $0 [unit|integration|eval|all] [model-id] [--show-results]"; exit 2 ;;
esac

# When --show-results is passed without an explicit mode, skip the test run
# and just open the visualizer for results from a previous eval run.
RUN_TESTS=1
if [[ "$SHOW_RESULTS" -eq 1 && ${#POSITIONAL[@]} -eq 0 ]]; then
  RUN_TESTS=0
fi

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

# ---------------------------------------------------------------------------
# Ensure the LLM GDExtension is built (required for eval tests)
# ---------------------------------------------------------------------------
ensure_llm_extension() {
  local bin_dir="$PROJECT_DIR/addons/local_llm/bin"
  local editor_so="$bin_dir/liblocal_llm.linux.editor.x86_64.so"

  if [[ -f "$editor_so" ]]; then
    echo "[run_tests] LLM GDExtension found: $(basename "$editor_so")"
    return 0
  fi

  echo ""
  echo "[run_tests] LLM GDExtension not found -- building automatically ..."
  echo "[run_tests] (this is a one-time step; subsequent runs will skip it)"
  echo ""

  local build_script="$SCRIPT_DIR/build_llm_linux.sh"
  if [[ ! -x "$build_script" ]]; then
    echo "[run_tests] ERROR: Build script not found or not executable: $build_script" >&2
    exit 1
  fi

  "$build_script"

  if [[ ! -f "$editor_so" ]]; then
    echo "[run_tests] ERROR: Build completed but .so still missing: $editor_so" >&2
    exit 1
  fi

  echo ""
  echo "[run_tests] GDExtension build succeeded. Continuing with tests ..."
  echo ""
}

mkdir -p "$LOG_DIR" "$RESULTS_DIR"

# Disable editor auto server/client to keep tests isolated
export UGCWORLD_AUTOSTART_SERVER=0
export UGCWORLD_AUTOCONNECT=0

TEST_EXIT=0

if [[ "$RUN_TESTS" -eq 1 ]]; then
  # Pass model filter to eval tests (empty = run all models)
  export EVAL_MODEL_FILTER="${EVAL_MODEL}"
  if [[ -n "$EVAL_MODEL" ]]; then
    echo "[run_tests] Filtering eval tests to model: $EVAL_MODEL"
  fi

  # Eval mode requires the native LLM extension -- build it if missing
  if [[ "$MODE" == "eval" ]]; then
    ensure_llm_extension
  fi

  "$GODOT_BIN" --headless --path "$PROJECT_DIR" --editor --quit

  set +e
  "$GODOT_BIN" --headless --path "$PROJECT_DIR" \
    --script "res://addons/gdUnit4/bin/GdUnitRunner.gd" -- \
    "$MODE_FLAG" \
    --junit="res://artifacts/test-results/junit.xml"
  TEST_EXIT=$?
  set -e
  echo "[run_tests] Test runner exited with code: $TEST_EXIT"
fi

# ---------------------------------------------------------------------------
# Visual results viewer — opens a Godot window (NOT headless) showing all
# generated particle effects in a labeled grid.
# ---------------------------------------------------------------------------
if [[ "$SHOW_RESULTS" -eq 1 ]]; then
  echo ""
  echo "[run_tests] Launching particle effect visualizer ..."
  echo "[run_tests] Controls: ESC = quit, SPACE = replay effects"
  echo ""
  "$GODOT_BIN" --path "$PROJECT_DIR" \
    --script "res://test/eval/particle_eval_visualizer.gd"
fi

exit $TEST_EXIT
