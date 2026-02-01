#!/usr/bin/env bash
set -e

# Run the Python backend server
# Usage: ./run_server.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")/../ugc_backend"

echo "=== Starting UGC Backend Server ==="
echo "Directory: $BACKEND_DIR"
echo ""

cd "$BACKEND_DIR"

# Check if requirements are installed
if ! python -c "import websockets" 2>/dev/null; then
    echo "Installing requirements..."
    pip install -r requirements.txt
fi

python app.py
