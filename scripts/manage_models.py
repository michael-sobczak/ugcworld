#!/usr/bin/env python3
"""
AI Model Manager for UGC World

Downloads, manages, and integrates GGUF models into the Godot client.
Supports resumable downloads, progress tracking, and cross-platform builds.

Usage:
    python manage_models.py                    # Interactive mode
    python manage_models.py --list             # List available models
    python manage_models.py --download all     # Download all models
    python manage_models.py --download qwen    # Download specific model
    python manage_models.py --clean            # Remove all models
    python manage_models.py --status           # Show installed models
    python manage_models.py --verify           # Verify Godot integration
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

# Check for required packages
try:
    import requests
    from tqdm import tqdm
except ImportError:
    print("Installing required packages...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "requests", "tqdm", "-q"])
    import requests
    from tqdm import tqdm


# =============================================================================
# Model Definitions
# =============================================================================

MODELS = {
    "qwen2.5-14b-instruct": {
        "display_name": "Qwen 2.5 14B Instruct (Q4_K_M)",
        "description": "Conversational UI - Best for natural dialogue and user interactions",
        "use_case": "conversational",
        "url": "https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/qwen2.5-14b-instruct-q4_k_m.gguf",
        "filename": "qwen2.5-14b-instruct-q4_k_m.gguf",
        "size_bytes": 8_690_000_000,  # ~8.1 GB
        "sha256": "",  # Will be computed on first download
        "context_length": 32768,
        "quantization": "Q4_K_M",
        "recommended_threads": 8,
        "tags": ["conversational", "14b", "quantized"],
        "prompt_template": {
            "system_prefix": "<|im_start|>system\n",
            "system_suffix": "<|im_end|>\n",
            "user_prefix": "<|im_start|>user\n",
            "user_suffix": "<|im_end|>\n",
            "assistant_prefix": "<|im_start|>assistant\n",
            "assistant_suffix": "<|im_end|>\n"
        }
    },
    "phi-3.5-instruct": {
        "display_name": "Phi-3.5 Mini Instruct (Q4_K_M)",
        "description": "Lightweight chat - Fast responses, lower memory usage",
        "use_case": "lightweight",
        "url": "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf",
        "filename": "phi-3.5-mini-instruct-q4_k_m.gguf",
        "size_bytes": 2_390_000_000,  # ~2.2 GB
        "sha256": "",
        "context_length": 131072,
        "quantization": "Q4_K_M",
        "recommended_threads": 4,
        "tags": ["lightweight", "3.8b", "quantized", "fast"],
        "prompt_template": {
            "system_prefix": "<|system|>\n",
            "system_suffix": "<|end|>\n",
            "user_prefix": "<|user|>\n",
            "user_suffix": "<|end|>\n",
            "assistant_prefix": "<|assistant|>\n",
            "assistant_suffix": "<|end|>\n"
        }
    },
    "qwen2.5-coder-14b": {
        "display_name": "Qwen 2.5 Coder 14B (Q4_K_M)",
        "description": "Agent planner - Code generation and planning for spell systems",
        "use_case": "coding",
        "url": "https://huggingface.co/Qwen/Qwen2.5-Coder-14B-Instruct-GGUF/resolve/main/qwen2.5-coder-14b-instruct-q4_k_m.gguf",
        "filename": "qwen2.5-coder-14b-instruct-q4_k_m.gguf",
        "size_bytes": 8_693_714_944,  # ~8.1 GB
        "sha256": "",
        "context_length": 32768,
        "quantization": "Q4_K_M",
        "recommended_threads": 8,
        "tags": ["coding", "14b", "quantized", "default"],
        "prompt_template": {
            "system_prefix": "<|im_start|>system\n",
            "system_suffix": "<|im_end|>\n",
            "user_prefix": "<|im_start|>user\n",
            "user_suffix": "<|im_end|>\n",
            "assistant_prefix": "<|im_start|>assistant\n",
            "assistant_suffix": "<|im_end|>\n"
        }
    },
    "deepseek-coder-v2": {
        "display_name": "DeepSeek Coder V2 Lite (Q4_K_M)",
        "description": "Deterministic executor - Precise code execution and validation",
        "use_case": "executor",
        "url": "https://huggingface.co/bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF/resolve/main/DeepSeek-Coder-V2-Lite-Instruct-Q4_K_M.gguf",
        "filename": "deepseek-coder-v2-lite-instruct-q4_k_m.gguf",
        "size_bytes": 8_940_000_000,  # ~8.3 GB
        "sha256": "",
        "context_length": 163840,
        "quantization": "Q4_K_M",
        "recommended_threads": 8,
        "tags": ["coding", "executor", "16b", "quantized"],
        "prompt_template": {
            "system_prefix": "",
            "system_suffix": "\n\n",
            "user_prefix": "### Instruction:\n",
            "user_suffix": "\n\n",
            "assistant_prefix": "### Response:\n",
            "assistant_suffix": "\n\n"
        }
    },
    "deepseek-r1-distill-14b": {
        "display_name": "DeepSeek R1 Distill Qwen 14B (Q4_K_M)",
        "description": "Reasoning model - Chain-of-thought reasoning distilled from DeepSeek R1, strong at code and math",
        "use_case": "reasoning",
        "url": "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf",
        "filename": "deepseek-r1-distill-qwen-14b-q4_k_m.gguf",
        "size_bytes": 9_650_544_640,  # ~9.0 GB
        "sha256": "",
        "context_length": 131072,
        "quantization": "Q4_K_M",
        "recommended_threads": 8,
        "tags": ["reasoning", "coding", "14b", "quantized", "r1"],
        "prompt_template": {
            "system_prefix": "<|begin▁of▁sentence|>",
            "system_suffix": "\n",
            "user_prefix": "<|User|>",
            "user_suffix": "\n",
            "assistant_prefix": "<|Assistant|>",
            "assistant_suffix": "\n"
        }
    },
    "qwen3-32b": {
        "display_name": "Qwen3 32B (Q4_K_M)",
        "description": "Flagship model - Latest Qwen3 32B with thinking mode, strongest overall quality",
        "use_case": "flagship",
        "url": "https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf",
        "filename": "qwen3-32b-q4_k_m.gguf",
        "size_bytes": 21_222_211_584,  # ~19.8 GB
        "sha256": "",
        "context_length": 131072,
        "quantization": "Q4_K_M",
        "recommended_threads": 8,
        "tags": ["reasoning", "coding", "32b", "quantized", "flagship"],
        "prompt_template": {
            "system_prefix": "<|im_start|>system\n",
            "system_suffix": "<|im_end|>\n",
            "user_prefix": "<|im_start|>user\n",
            "user_suffix": "<|im_end|>\n",
            "assistant_prefix": "<|im_start|>assistant\n",
            "assistant_suffix": "<|im_end|>\n"
        }
    }
}

# Aliases for easier command line usage
MODEL_ALIASES = {
    "qwen": "qwen2.5-14b-instruct",
    "qwen-instruct": "qwen2.5-14b-instruct",
    "conversational": "qwen2.5-14b-instruct",
    "phi": "phi-3.5-instruct",
    "phi3": "phi-3.5-instruct",
    "lightweight": "phi-3.5-instruct",
    "fast": "phi-3.5-instruct",
    "coder": "qwen2.5-coder-14b",
    "qwen-coder": "qwen2.5-coder-14b",
    "planner": "qwen2.5-coder-14b",
    "deepseek": "deepseek-coder-v2",
    "executor": "deepseek-coder-v2",
    "deepseek-r1": "deepseek-r1-distill-14b",
    "r1": "deepseek-r1-distill-14b",
    "reasoning": "deepseek-r1-distill-14b",
    "r1-distill": "deepseek-r1-distill-14b",
    "qwen3": "qwen3-32b",
    "qwen3-32b": "qwen3-32b",
    "flagship": "qwen3-32b",
}


# =============================================================================
# Paths
# =============================================================================

def get_script_dir() -> Path:
    return Path(__file__).parent.absolute()


def get_project_root() -> Path:
    return get_script_dir().parent


def get_models_dir() -> Path:
    return get_project_root() / "player-created-world" / "models"


def get_models_json_path() -> Path:
    return get_models_dir() / "models.json"


def get_state_file() -> Path:
    return get_models_dir() / ".download_state.json"


# =============================================================================
# State Management (for resume support)
# =============================================================================

def load_state() -> dict:
    """Load download state for resume support."""
    state_file = get_state_file()
    if state_file.exists():
        try:
            with open(state_file, "r") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return {"downloads": {}, "completed": []}


def save_state(state: dict) -> None:
    """Save download state."""
    state_file = get_state_file()
    with open(state_file, "w") as f:
        json.dump(state, f, indent=2)


def clear_state() -> None:
    """Clear download state."""
    state_file = get_state_file()
    if state_file.exists():
        state_file.unlink()


# =============================================================================
# Download Functions
# =============================================================================

def get_file_size(url: str) -> Optional[int]:
    """Get file size from URL without downloading."""
    try:
        response = requests.head(url, allow_redirects=True, timeout=10)
        if response.status_code == 200:
            return int(response.headers.get("content-length", 0))
    except requests.RequestException:
        pass
    return None


def download_file(url: str, dest_path: Path, expected_size: int = 0, 
                  resume: bool = True) -> bool:
    """
    Download a file with progress bar and resume support.
    
    Returns True if download completed successfully.
    """
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    
    # Check for partial download
    partial_path = dest_path.with_suffix(dest_path.suffix + ".partial")
    initial_size = 0
    
    if resume and partial_path.exists():
        initial_size = partial_path.stat().st_size
        print(f"  Resuming from {format_size(initial_size)}...")
    
    headers = {}
    if initial_size > 0:
        headers["Range"] = f"bytes={initial_size}-"
    
    try:
        response = requests.get(url, headers=headers, stream=True, timeout=30)
        
        # Handle resume response
        if response.status_code == 416:  # Range not satisfiable - file complete
            if partial_path.exists():
                partial_path.replace(dest_path)  # .replace() works on Windows even if dest exists
            return True
        
        if response.status_code not in (200, 206):
            print(f"  Error: HTTP {response.status_code}")
            return False
        
        # Get total size
        total_size = int(response.headers.get("content-length", 0))
        if response.status_code == 206:
            total_size += initial_size
        elif expected_size > 0:
            total_size = expected_size
        
        # Open file for writing (append if resuming)
        mode = "ab" if initial_size > 0 else "wb"
        
        with open(partial_path, mode) as f:
            with tqdm(
                total=total_size,
                initial=initial_size,
                unit="B",
                unit_scale=True,
                unit_divisor=1024,
                desc="  Downloading",
                ncols=80,
                bar_format="{l_bar}{bar}| {n_fmt}/{total_fmt} [{rate_fmt}]"
            ) as pbar:
                for chunk in response.iter_content(chunk_size=1024 * 1024):  # 1MB chunks
                    if chunk:
                        f.write(chunk)
                        pbar.update(len(chunk))
        
        # Rename partial to final (use .replace() for Windows compatibility)
        partial_path.replace(dest_path)
        return True
        
    except requests.RequestException as e:
        print(f"  Download error: {e}")
        return False
    except KeyboardInterrupt:
        print("\n  Download interrupted. Run again to resume.")
        return False


def compute_sha256(file_path: Path, show_progress: bool = True) -> str:
    """Compute SHA256 hash of a file."""
    sha256 = hashlib.sha256()
    file_size = file_path.stat().st_size
    
    with open(file_path, "rb") as f:
        if show_progress and file_size > 100_000_000:  # Show progress for files > 100MB
            with tqdm(
                total=file_size,
                unit="B",
                unit_scale=True,
                desc="  Verifying",
                ncols=80
            ) as pbar:
                while chunk := f.read(1024 * 1024):
                    sha256.update(chunk)
                    pbar.update(len(chunk))
        else:
            while chunk := f.read(1024 * 1024):
                sha256.update(chunk)
    
    return sha256.hexdigest()


# =============================================================================
# Model Management
# =============================================================================

def resolve_model_name(name: str) -> Optional[str]:
    """Resolve model name or alias to canonical ID."""
    name_lower = name.lower().strip()
    
    if name_lower in MODELS:
        return name_lower
    
    if name_lower in MODEL_ALIASES:
        return MODEL_ALIASES[name_lower]
    
    # Fuzzy match
    for model_id in MODELS:
        if name_lower in model_id:
            return model_id
    
    return None


def get_installed_models() -> list[str]:
    """Get list of installed model IDs."""
    models_dir = get_models_dir()
    installed = []
    
    for model_id, info in MODELS.items():
        model_path = models_dir / info["filename"]
        if model_path.exists():
            installed.append(model_id)
    
    return installed


def download_model(model_id: str, force: bool = False) -> bool:
    """Download a single model."""
    if model_id not in MODELS:
        print(f"Unknown model: {model_id}")
        return False
    
    info = MODELS[model_id]
    models_dir = get_models_dir()
    model_path = models_dir / info["filename"]
    
    print(f"\n{'='*60}")
    print(f"Model: {info['display_name']}")
    print(f"Use case: {info['description']}")
    print(f"Size: ~{format_size(info['size_bytes'])}")
    print(f"{'='*60}")
    
    # Check if already installed
    if model_path.exists() and not force:
        existing_size = model_path.stat().st_size
        if abs(existing_size - info["size_bytes"]) < 1000000:  # Within 1MB
            print(f"  ✓ Already installed ({format_size(existing_size)})")
            return True
        else:
            print(f"  Existing file size mismatch, re-downloading...")
    
    # Download
    print(f"  Downloading from: {info['url'][:60]}...")
    success = download_file(
        info["url"],
        model_path,
        expected_size=info["size_bytes"]
    )
    
    if success:
        # Update state
        state = load_state()
        if model_id not in state["completed"]:
            state["completed"].append(model_id)
        save_state(state)
        
        print(f"  ✓ Download complete!")
        return True
    else:
        print(f"  ✗ Download failed")
        return False


def update_models_json() -> None:
    """Update the Godot client's models.json with installed models."""
    models_dir = get_models_dir()
    models_json_path = get_models_json_path()
    
    # Get installed models
    installed = get_installed_models()
    
    if not installed:
        print("\nNo models installed to integrate.")
        return
    
    # Build models array
    models_array = []
    for model_id in installed:
        info = MODELS[model_id]
        model_path = models_dir / info["filename"]
        
        model_entry = {
            "id": model_id,
            "display_name": info["display_name"],
            "backend": "llama.cpp",
            "context_length": info["context_length"],
            "recommended_threads": info["recommended_threads"],
            "quantization": info["quantization"],
            "file_path_in_pck": f"res://models/{info['filename']}",
            "sha256": info.get("sha256", ""),
            "size_bytes": model_path.stat().st_size if model_path.exists() else info["size_bytes"],
            "estimated_memory": int(info["size_bytes"] * 1.2),
            "description": info["description"],
            "tags": info["tags"],
            "prompt_template": info["prompt_template"]
        }
        models_array.append(model_entry)
    
    # Build full config
    config = {
        "version": "1.0",
        "description": "Local LLM Model Registry - Managed by manage_models.py",
        "models": models_array,
        "presets": {
            "coding": {
                "temperature": 0.0,
                "top_p": 0.9,
                "top_k": 40,
                "repeat_penalty": 1.1,
                "max_tokens": 1024,
                "system_prompt": "You are a helpful coding assistant. Provide clear, concise, and correct code solutions."
            },
            "creative": {
                "temperature": 0.0,
                "top_p": 0.95,
                "top_k": 50,
                "repeat_penalty": 1.05,
                "max_tokens": 512,
                "system_prompt": "You are a creative writing assistant."
            },
            "precise": {
                "temperature": 0.0,
                "top_p": 0.8,
                "top_k": 20,
                "repeat_penalty": 1.2,
                "max_tokens": 256,
                "system_prompt": "You are a precise technical assistant. Be accurate and concise."
            },
            "conversational": {
                "temperature": 0.0,
                "top_p": 0.9,
                "top_k": 40,
                "repeat_penalty": 1.1,
                "max_tokens": 512,
                "system_prompt": "You are a friendly and helpful assistant."
            }
        }
    }
    
    # Write config
    with open(models_json_path, "w") as f:
        json.dump(config, f, indent="\t")
    
    print(f"\n✓ Updated {models_json_path}")
    print(f"  Integrated {len(models_array)} model(s)")


def clean_models(confirm: bool = True) -> None:
    """Remove all downloaded models and reset config."""
    models_dir = get_models_dir()
    
    if confirm:
        print("\nThis will remove all downloaded models:")
        for model_id, info in MODELS.items():
            model_path = models_dir / info["filename"]
            if model_path.exists():
                print(f"  - {info['display_name']} ({format_size(model_path.stat().st_size)})")
        
        response = input("\nAre you sure? (yes/no): ").strip().lower()
        if response != "yes":
            print("Cancelled.")
            return
    
    # Remove model files
    removed = 0
    for model_id, info in MODELS.items():
        model_path = models_dir / info["filename"]
        partial_path = model_path.with_suffix(model_path.suffix + ".partial")
        
        for path in [model_path, partial_path]:
            if path.exists():
                path.unlink()
                removed += 1
                print(f"  Removed: {path.name}")
    
    # Clear state
    clear_state()
    
    # Reset models.json to empty
    config = {
        "version": "1.0",
        "description": "Local LLM Model Registry - No models installed",
        "models": [],
        "presets": {}
    }
    with open(get_models_json_path(), "w") as f:
        json.dump(config, f, indent="\t")
    
    print(f"\n✓ Cleaned {removed} file(s)")


# =============================================================================
# Verification & Godot Integration
# =============================================================================

def get_gdextension_paths() -> dict:
    """Get paths to GDExtension binaries."""
    addon_dir = get_project_root() / "player-created-world" / "addons" / "local_llm" / "bin"
    
    system = platform.system().lower()
    if system == "windows":
        editor_lib = addon_dir / "liblocal_llm.windows.editor.x86_64.dll"
        release_lib = addon_dir / "liblocal_llm.windows.template_release.x86_64.dll"
    elif system == "linux":
        editor_lib = addon_dir / "liblocal_llm.linux.editor.x86_64.so"
        release_lib = addon_dir / "liblocal_llm.linux.template_release.x86_64.so"
    elif system == "darwin":
        editor_lib = addon_dir / "liblocal_llm.macos.editor.universal.framework" / "liblocal_llm.macos.editor.universal"
        release_lib = addon_dir / "liblocal_llm.macos.template_release.universal.framework" / "liblocal_llm.macos.template_release.universal"
    else:
        editor_lib = None
        release_lib = None
    
    return {
        "addon_dir": addon_dir,
        "editor": editor_lib,
        "release": release_lib,
        "system": system
    }


def verify_installation() -> bool:
    """
    Verify that models are correctly installed and ready for Godot.
    
    Checks:
    1. Models are in correct location (player-created-world/models/)
    2. models.json exists and is valid
    3. models.json references match actual files
    4. GDExtension is built (required for LLM to work)
    
    Returns True if all checks pass.
    """
    print("\n" + "="*60)
    print("Verifying Godot LLM Integration")
    print("="*60)
    
    all_ok = True
    models_dir = get_models_dir()
    models_json_path = get_models_json_path()
    
    # Check 1: models.json exists
    print("\n[1] Checking models.json...")
    config = None
    models_list = []
    
    if not models_json_path.exists():
        print("    ✗ models.json not found")
        print(f"      Expected: {models_json_path}")
        all_ok = False
    else:
        print(f"    ✓ Found: {models_json_path}")
        
        # Validate JSON
        try:
            with open(models_json_path, "r") as f:
                config = json.load(f)
            
            models_list = config.get("models", [])
            print(f"    ✓ Valid JSON with {len(models_list)} model(s) registered")
        except json.JSONDecodeError as e:
            print(f"    ✗ Invalid JSON: {e}")
            all_ok = False
    
    # Check 2: Model files exist and match registry
    print("\n[2] Checking model files...")
    installed = get_installed_models()
    
    if not installed:
        print("    ○ No models installed")
        print("      Run: python manage_models.py --download all")
    else:
        for model_id in installed:
            info = MODELS[model_id]
            model_path = models_dir / info["filename"]
            actual_size = model_path.stat().st_size
            expected_size = info["size_bytes"]
            
            # Check size (allow 5% variance for different download sources)
            size_ok = abs(actual_size - expected_size) < expected_size * 0.05
            
            if size_ok:
                print(f"    ✓ {info['display_name']}")
                print(f"      {format_size(actual_size)} @ {model_path.name}")
            else:
                print(f"    ⚠ {info['display_name']} - size mismatch")
                print(f"      Expected: {format_size(expected_size)}, Actual: {format_size(actual_size)}")
                all_ok = False
    
    # Check 3: models.json references match files
    print("\n[3] Checking registry-to-file mapping...")
    if config and models_list:
        for model_entry in models_list:
            model_id = model_entry.get("id", "unknown")
            file_path = model_entry.get("file_path_in_pck", "")
            
            if file_path:
                # Extract filename from res://models/filename.gguf
                filename = file_path.split("/")[-1]
                actual_path = models_dir / filename
                
                if actual_path.exists():
                    print(f"    ✓ {model_id} -> {filename}")
                else:
                    print(f"    ✗ {model_id} -> {filename} (FILE NOT FOUND)")
                    all_ok = False
    else:
        print("    ○ No models in registry to check")
    
    # Check 4: GDExtension built
    print("\n[4] Checking GDExtension (llama.cpp wrapper)...")
    ext_paths = get_gdextension_paths()
    
    if ext_paths["editor"] and ext_paths["editor"].exists():
        print(f"    ✓ Editor extension found ({ext_paths['system']})")
        print(f"      {ext_paths['editor'].name}")
    else:
        print(f"    ✗ Editor extension NOT FOUND")
        print(f"      Models will not work without the GDExtension!")
        if ext_paths["system"] == "windows":
            print(f"      Build it: scripts\\build_llm_win.ps1")
        else:
            print(f"      Build it: scripts/build_llm_linux.sh")
        all_ok = False
    
    if ext_paths["release"] and ext_paths["release"].exists():
        print(f"    ✓ Release extension found")
    else:
        print(f"    ○ Release extension not found (optional for development)")
    
    # Summary
    print("\n" + "="*60)
    if all_ok:
        print("✓ All checks passed!")
        print("\nModels are ready to use in Godot.")
        print("Open the project and the LocalLLMService will auto-load models.")
    else:
        print("⚠ Some issues detected - see above for details")
    print("="*60)
    
    return all_ok


def print_next_steps() -> None:
    """Print helpful next steps after model download."""
    ext_paths = get_gdextension_paths()
    has_extension = ext_paths["editor"] and ext_paths["editor"].exists()
    
    print("\n" + "-"*60)
    print("Next Steps:")
    print("-"*60)
    
    if not has_extension:
        print("\n1. BUILD THE GDEXTENSION (required for LLM to work):")
        if ext_paths["system"] == "windows":
            print("   cd scripts")
            print("   .\\build_llm_win.ps1")
        else:
            print("   cd scripts")
            print("   ./build_llm_linux.sh")
        print("\n2. Open the Godot project:")
    else:
        print("\n1. Open the Godot project:")
    
    print("   player-created-world/project.godot")
    print("\n   The LocalLLMService autoload will detect and load models")
    print("   automatically from models.json.")
    
    print("\nVerify installation anytime:")
    print("   python manage_models.py --verify")
    
    print("\nFor packaging/distribution:")
    print("   scripts\\package_game.ps1 -Platform windows -ModelPath <model.gguf>")
    print("-"*60)


# =============================================================================
# UI Helpers
# =============================================================================

def format_size(size_bytes: int) -> str:
    """Format bytes as human-readable size."""
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"


def print_models_table() -> None:
    """Print a table of available models."""
    installed = get_installed_models()
    
    print("\n" + "="*70)
    print("Available Models")
    print("="*70)
    
    for model_id, info in MODELS.items():
        status = "✓ Installed" if model_id in installed else "  Available"
        print(f"\n{status}  {info['display_name']}")
        print(f"          ID: {model_id}")
        print(f"          Use: {info['description']}")
        print(f"          Size: ~{format_size(info['size_bytes'])}")
    
    print("\n" + "-"*70)
    print("Aliases for download command:")
    aliases_by_model = {}
    for alias, model_id in MODEL_ALIASES.items():
        if model_id not in aliases_by_model:
            aliases_by_model[model_id] = []
        aliases_by_model[model_id].append(alias)
    
    for model_id, aliases in aliases_by_model.items():
        print(f"  {model_id}: {', '.join(aliases)}")
    print("="*70)


def print_status() -> None:
    """Print current installation status."""
    models_dir = get_models_dir()
    installed = get_installed_models()
    
    print("\n" + "="*60)
    print("Model Installation Status")
    print("="*60)
    
    total_size = 0
    for model_id, info in MODELS.items():
        model_path = models_dir / info["filename"]
        
        if model_id in installed:
            size = model_path.stat().st_size
            total_size += size
            print(f"  ✓ {info['display_name']}")
            print(f"      {format_size(size)} - {model_path.name}")
        else:
            partial = model_path.with_suffix(model_path.suffix + ".partial")
            if partial.exists():
                partial_size = partial.stat().st_size
                pct = (partial_size / info["size_bytes"]) * 100
                print(f"  ◐ {info['display_name']} (downloading: {pct:.1f}%)")
            else:
                print(f"  ○ {info['display_name']} (not installed)")
    
    print("-"*60)
    print(f"Total installed: {len(installed)}/{len(MODELS)} models")
    print(f"Total size: {format_size(total_size)}")
    print("="*60)


def interactive_menu() -> None:
    """Show interactive menu for model management."""
    while True:
        print("\n" + "="*50)
        print("  UGC World - AI Model Manager")
        print("="*50)
        print("\n  1. List available models")
        print("  2. Show installation status")
        print("  3. Download all models")
        print("  4. Download specific model")
        print("  5. Verify Godot integration")
        print("  6. Clean all models")
        print("  7. Update Godot integration")
        print("  8. Exit")
        
        try:
            choice = input("\nSelect option (1-8): ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n")
            break
        
        if choice == "1":
            print_models_table()
        elif choice == "2":
            print_status()
        elif choice == "3":
            download_all_models(show_next_steps=False)
        elif choice == "4":
            print("\nAvailable models:")
            for i, model_id in enumerate(MODELS.keys(), 1):
                print(f"  {i}. {model_id}")
            try:
                sel = input("\nEnter model number or name: ").strip()
                if sel.isdigit():
                    idx = int(sel) - 1
                    if 0 <= idx < len(MODELS):
                        model_id = list(MODELS.keys())[idx]
                        download_model(model_id)
                        update_models_json()
                else:
                    model_id = resolve_model_name(sel)
                    if model_id:
                        download_model(model_id)
                        update_models_json()
                    else:
                        print(f"Unknown model: {sel}")
            except (EOFError, KeyboardInterrupt):
                pass
        elif choice == "5":
            verify_installation()
        elif choice == "6":
            clean_models()
        elif choice == "7":
            update_models_json()
        elif choice == "8":
            break


def download_all_models(show_next_steps: bool = True) -> None:
    """Download all models."""
    print("\nDownloading all models...")
    print(f"Total: {len(MODELS)} models, ~{format_size(sum(m['size_bytes'] for m in MODELS.values()))}")
    
    success = 0
    for model_id in MODELS:
        if download_model(model_id):
            success += 1
    
    print(f"\n{'='*60}")
    print(f"Download complete: {success}/{len(MODELS)} models")
    print(f"{'='*60}")
    
    if success > 0:
        update_models_json()
        if show_next_steps:
            print_next_steps()


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="AI Model Manager for UGC World",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python manage_models.py                     Interactive mode
  python manage_models.py --list              List available models
  python manage_models.py --download all      Download all models
  python manage_models.py --download coder    Download Qwen2.5-Coder
  python manage_models.py --download phi      Download Phi-3.5
  python manage_models.py --status            Show installed models
  python manage_models.py --verify            Verify Godot integration
  python manage_models.py --clean             Remove all models

After downloading, the script will verify:
  - Models are in the correct location
  - models.json is updated with model metadata  
  - GDExtension (llama.cpp wrapper) is built

The GDExtension must be built separately:
  Windows: scripts\\build_llm_win.ps1
  Linux:   scripts/build_llm_linux.sh
        """
    )
    
    parser.add_argument(
        "--list", "-l",
        action="store_true",
        help="List available models"
    )
    
    parser.add_argument(
        "--download", "-d",
        metavar="MODEL",
        nargs="?",
        const="prompt",
        help="Download model(s). Use 'all' for all models, or model name/alias"
    )
    
    parser.add_argument(
        "--status", "-s",
        action="store_true",
        help="Show installation status"
    )
    
    parser.add_argument(
        "--clean", "-c",
        action="store_true",
        help="Remove all downloaded models and reset config"
    )
    
    parser.add_argument(
        "--integrate", "-i",
        action="store_true",
        help="Update Godot models.json with installed models"
    )
    
    parser.add_argument(
        "--force", "-f",
        action="store_true",
        help="Force re-download even if model exists"
    )
    
    parser.add_argument(
        "--yes", "-y",
        action="store_true",
        help="Skip confirmation prompts"
    )
    
    parser.add_argument(
        "--verify", "-v",
        action="store_true",
        help="Verify models are correctly installed and ready for Godot"
    )
    
    args = parser.parse_args()
    
    # Ensure models directory exists
    get_models_dir().mkdir(parents=True, exist_ok=True)
    
    # Handle commands
    if args.list:
        print_models_table()
    elif args.status:
        print_status()
    elif args.clean:
        clean_models(confirm=not args.yes)
    elif args.integrate:
        update_models_json()
    elif args.verify:
        success = verify_installation()
        sys.exit(0 if success else 1)
    elif args.download:
        if args.download == "prompt":
            # Interactive download selection
            print_models_table()
            try:
                sel = input("\nEnter model name to download (or 'all'): ").strip()
                if sel.lower() == "all":
                    download_all_models()
                else:
                    model_id = resolve_model_name(sel)
                    if model_id:
                        download_model(model_id, force=args.force)
                        update_models_json()
                        print_next_steps()
                    else:
                        print(f"Unknown model: {sel}")
                        sys.exit(1)
            except (EOFError, KeyboardInterrupt):
                print("\nCancelled.")
        elif args.download.lower() == "all":
            download_all_models()
        else:
            model_id = resolve_model_name(args.download)
            if model_id:
                download_model(model_id, force=args.force)
                update_models_json()
                print_next_steps()
            else:
                print(f"Unknown model: {args.download}")
                print("Use --list to see available models")
                sys.exit(1)
    else:
        # Interactive mode
        interactive_menu()


if __name__ == "__main__":
    main()
