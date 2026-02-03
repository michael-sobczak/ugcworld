"""
Spell package storage module.
Handles file system operations for spell revisions.
"""

import os
import json
import hashlib
import shutil
from datetime import datetime
from typing import Optional, Dict, Any, List

# Base directory for spell storage
DATA_DIR = os.path.join(os.path.dirname(__file__), "data")
SPELLS_DIR = os.path.join(DATA_DIR, "spells")
BLOBS_DIR = os.path.join(DATA_DIR, "blobs", "sha256")


def ensure_directories():
    """Ensure storage directories exist."""
    os.makedirs(SPELLS_DIR, exist_ok=True)
    os.makedirs(BLOBS_DIR, exist_ok=True)


def get_spell_dir(spell_id: str) -> str:
    """Get the directory path for a spell."""
    return os.path.join(SPELLS_DIR, spell_id)


def get_revision_dir(spell_id: str, revision_id: str) -> str:
    """Get the directory path for a specific revision."""
    return os.path.join(get_spell_dir(spell_id), "revisions", revision_id)


def get_manifest_path(spell_id: str, revision_id: str) -> str:
    """Get the manifest.json path for a revision."""
    return os.path.join(get_revision_dir(spell_id, revision_id), "manifest.json")


def compute_file_hash(content: bytes) -> str:
    """Compute SHA256 hash of file content."""
    return hashlib.sha256(content).hexdigest()


# ============================================================================
# Revision Storage
# ============================================================================

def create_revision_directory(spell_id: str, revision_id: str) -> str:
    """Create the directory structure for a new revision."""
    ensure_directories()
    
    revision_dir = get_revision_dir(spell_id, revision_id)
    code_dir = os.path.join(revision_dir, "code")
    assets_dir = os.path.join(revision_dir, "assets")
    text_dir = os.path.join(revision_dir, "text")
    
    os.makedirs(code_dir, exist_ok=True)
    os.makedirs(assets_dir, exist_ok=True)
    os.makedirs(text_dir, exist_ok=True)
    
    return revision_dir


def write_revision_file(
    spell_id: str, 
    revision_id: str, 
    relative_path: str, 
    content: bytes
) -> Dict[str, Any]:
    """Write a file to a revision directory and return file info."""
    revision_dir = get_revision_dir(spell_id, revision_id)
    file_path = os.path.join(revision_dir, relative_path)
    
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    
    with open(file_path, "wb") as f:
        f.write(content)
    
    file_hash = compute_file_hash(content)
    return {
        "path": relative_path,
        "hash": file_hash,
        "size": len(content)
    }


def write_revision_file_text(
    spell_id: str,
    revision_id: str,
    relative_path: str,
    content: str
) -> Dict[str, Any]:
    """Write a text file to a revision directory."""
    return write_revision_file(spell_id, revision_id, relative_path, content.encode("utf-8"))


def read_revision_file(spell_id: str, revision_id: str, relative_path: str) -> Optional[bytes]:
    """Read a file from a revision directory."""
    file_path = os.path.join(get_revision_dir(spell_id, revision_id), relative_path)
    
    if not os.path.exists(file_path):
        return None
    
    with open(file_path, "rb") as f:
        return f.read()


def revision_exists(spell_id: str, revision_id: str) -> bool:
    """Check if a revision directory exists."""
    return os.path.exists(get_revision_dir(spell_id, revision_id))


def list_revision_files(spell_id: str, revision_id: str) -> List[str]:
    """List all files in a revision (relative paths)."""
    revision_dir = get_revision_dir(spell_id, revision_id)
    
    if not os.path.exists(revision_dir):
        return []
    
    files = []
    for root, dirs, filenames in os.walk(revision_dir):
        for filename in filenames:
            full_path = os.path.join(root, filename)
            rel_path = os.path.relpath(full_path, revision_dir)
            files.append(rel_path.replace("\\", "/"))
    
    return files


# ============================================================================
# Manifest Operations
# ============================================================================

def create_manifest(
    spell_id: str,
    revision_id: str,
    version: int,
    entrypoint: str = "code/spell.gd",
    metadata: Dict[str, Any] = None,
    code_files: List[Dict[str, Any]] = None,
    asset_files: List[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """Create a manifest dictionary."""
    now = datetime.utcnow().isoformat()
    
    manifest = {
        "spell_id": spell_id,
        "revision_id": revision_id,
        "version": version,
        "created_at": now,
        "entrypoint": entrypoint,
        "language": "gdscript",
        "interface_version": "1.0",
        "code": code_files or [],
        "assets": asset_files or [],
        "metadata": metadata or {
            "name": spell_id.replace("_", " ").title(),
            "description": f"A spell package for {spell_id}",
            "tags": [],
            "preview_icon": None
        }
    }
    
    return manifest


def write_manifest(spell_id: str, revision_id: str, manifest: Dict[str, Any]) -> str:
    """Write manifest.json to the revision directory."""
    manifest_path = get_manifest_path(spell_id, revision_id)
    
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    
    return manifest_path


def read_manifest(spell_id: str, revision_id: str) -> Optional[Dict[str, Any]]:
    """Read manifest.json from a revision directory."""
    manifest_path = get_manifest_path(spell_id, revision_id)
    
    if not os.path.exists(manifest_path):
        return None
    
    with open(manifest_path, "r", encoding="utf-8") as f:
        return json.load(f)


def delete_revision(spell_id: str, revision_id: str) -> bool:
    """Delete a revision directory."""
    revision_dir = get_revision_dir(spell_id, revision_id)
    
    if os.path.exists(revision_dir):
        shutil.rmtree(revision_dir)
        return True
    
    return False


# Initialize directories on import
ensure_directories()
