#!/bin/bash
#
# AI Model Manager for UGC World (Bash wrapper)
#
# Downloads, manages, and integrates GGUF models into the Godot client.
#
# Examples:
#   ./manage_models.sh                    # Interactive mode
#   ./manage_models.sh --list             # List available models  
#   ./manage_models.sh --download all     # Download all models
#   ./manage_models.sh --download coder   # Download Qwen2.5-Coder
#   ./manage_models.sh --clean            # Remove all models

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/manage_models.py"

# Find Python 3
PYTHON=""
for cmd in python3 python; do
    if command -v $cmd &> /dev/null; then
        version=$($cmd --version 2>&1)
        if [[ $version == *"Python 3"* ]]; then
            PYTHON=$cmd
            break
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    echo "ERROR: Python 3 not found. Please install Python 3.8 or later."
    exit 1
fi

# Install requirements if needed
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements-models.txt"
if [ -f "$REQUIREMENTS_FILE" ]; then
    $PYTHON -m pip install -q -r "$REQUIREMENTS_FILE" 2>/dev/null || true
fi

# Run the Python script with all arguments
exec $PYTHON "$PYTHON_SCRIPT" "$@"
