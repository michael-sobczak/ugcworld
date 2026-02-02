#!/bin/bash
#
# Build script for Local LLM GDExtension on Linux
#
# This script:
# 1. Clones/updates llama.cpp and godot-cpp as submodules
# 2. Builds llama.cpp as a static library
# 3. Builds the GDExtension for Linux (Debug + Release)
#
# Usage:
#   ./build_llm_linux.sh [options]
#
# Options:
#   --target debug|release|all   Build target (default: all)
#   --clean                      Clean build directories before building
#   --cuda                       Enable CUDA support
#   --vulkan                     Enable Vulkan support
#   -j N                         Number of parallel jobs (default: auto)
#
# Examples:
#   ./build_llm_linux.sh
#   ./build_llm_linux.sh --target release
#   ./build_llm_linux.sh --clean --cuda

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# Parse arguments
TARGET="all"
CLEAN=false
CUDA=false
VULKAN=false
JOBS=$(nproc)

while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --cuda)
            CUDA=true
            shift
            ;;
        --vulkan)
            VULKAN=true
            shift
            ;;
        -j)
            JOBS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ADDON_DIR="$PROJECT_ROOT/player-created-world/addons/local_llm"
SRC_DIR="$ADDON_DIR/src"
BIN_DIR="$ADDON_DIR/bin"

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Local LLM GDExtension Build Script${NC}"
echo -e "${CYAN}  Platform: Linux${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

cd "$SRC_DIR"

# Step 1: Initialize dependencies
echo -e "${YELLOW}[1/5] Checking dependencies...${NC}"

if [ ! -d "llama.cpp" ]; then
    echo -e "${GRAY}  Cloning llama.cpp...${NC}"
    git clone --depth 1 https://github.com/ggerganov/llama.cpp.git
else
    echo -e "${GRAY}  llama.cpp already present${NC}"
fi

if [ ! -d "godot-cpp" ]; then
    echo -e "${GRAY}  Cloning godot-cpp...${NC}"
    git clone --depth 1 --branch 4.4 https://github.com/godotengine/godot-cpp.git
else
    echo -e "${GRAY}  godot-cpp already present${NC}"
fi

# Step 2: Clean if requested
if [ "$CLEAN" = true ]; then
    echo -e "${YELLOW}[2/5] Cleaning build directories...${NC}"
    rm -rf llama.cpp/build
    rm -rf build
    rm -rf "$BIN_DIR"
else
    echo -e "${GRAY}[2/5] Skipping clean (use --clean to force)${NC}"
fi

# Ensure bin directory exists
mkdir -p "$BIN_DIR"

# Step 3: Build llama.cpp
echo -e "${YELLOW}[3/5] Building llama.cpp...${NC}"

mkdir -p llama.cpp/build
cd llama.cpp/build

CMAKE_ARGS=(
    ".."
    "-DCMAKE_BUILD_TYPE=Release"
    "-DBUILD_SHARED_LIBS=OFF"
    "-DLLAMA_BUILD_TESTS=OFF"
    "-DLLAMA_BUILD_EXAMPLES=OFF"
    "-DLLAMA_BUILD_SERVER=OFF"
    "-DGGML_NATIVE=OFF"
)

if [ "$CUDA" = true ]; then
    echo -e "${GREEN}  CUDA support enabled${NC}"
    CMAKE_ARGS+=("-DGGML_CUDA=ON")
fi

if [ "$VULKAN" = true ]; then
    echo -e "${GREEN}  Vulkan support enabled${NC}"
    CMAKE_ARGS+=("-DGGML_VULKAN=ON")
fi

echo -e "${GRAY}  Running CMake configure...${NC}"
cmake "${CMAKE_ARGS[@]}"

echo -e "${GRAY}  Building...${NC}"
cmake --build . --config Release --parallel "$JOBS"

cd "$SRC_DIR"

# Step 4: Build godot-cpp
echo -e "${YELLOW}[4/5] Building godot-cpp...${NC}"

cd godot-cpp

if [ "$TARGET" = "all" ] || [ "$TARGET" = "release" ]; then
    echo -e "${GRAY}  Building Release...${NC}"
    scons platform=linux target=template_release arch=x86_64 -j"$JOBS"
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "debug" ]; then
    echo -e "${GRAY}  Building Debug...${NC}"
    scons platform=linux target=template_debug arch=x86_64 -j"$JOBS"
fi

cd "$SRC_DIR"

# Step 5: Build the extension
echo -e "${YELLOW}[5/5] Building Local LLM Extension...${NC}"

if [ "$TARGET" = "all" ] || [ "$TARGET" = "release" ]; then
    echo -e "${GRAY}  Building Release...${NC}"
    scons platform=linux target=template_release arch=x86_64 -j"$JOBS"
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "debug" ]; then
    echo -e "${GRAY}  Building Debug...${NC}"
    scons platform=linux target=template_debug arch=x86_64 -j"$JOBS"
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Build Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${CYAN}Output files in: $BIN_DIR${NC}"
ls -la "$BIN_DIR"/*.so 2>/dev/null || echo "  (no .so files found - check for build errors)"
