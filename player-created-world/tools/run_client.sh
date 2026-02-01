#!/usr/bin/env bash
set -e

# Run the Godot client
# Usage: ./run_client.sh [godot_path]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

GODOT="${1:-godot}"

echo "=== Starting UGC World Client ==="
echo "Project: $PROJECT_DIR"
echo "Godot: $GODOT"
echo ""
echo "Controls:"
echo "  C/Enter - Connect to server (auto-connects by default)"
echo "  1       - Create terrain"
echo "  2       - Dig terrain"
echo "  WASD    - Move camera"
echo "  RMB     - Toggle mouse look"
echo ""
echo "Make sure the backend is running: cd ../ugc_backend && python app.py"
echo ""

cd "$PROJECT_DIR"
"$GODOT" --main-scene "res://client/scenes/Main.tscn"
