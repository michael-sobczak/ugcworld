"""
Database module for spell package system.
Uses SQLite for metadata storage.

Supports multi-world architecture where a single server can host multiple worlds.
"""

import sqlite3
import json
import os
import uuid
from datetime import datetime
from typing import Optional, List, Dict, Any
from contextlib import contextmanager

DATABASE_PATH = os.path.join(os.path.dirname(__file__), "data", "spells.db")


def ensure_data_dir():
    """Ensure data directory exists."""
    data_dir = os.path.dirname(DATABASE_PATH)
    os.makedirs(data_dir, exist_ok=True)


@contextmanager
def get_connection():
    """Get a database connection with row factory."""
    ensure_data_dir()
    conn = sqlite3.connect(DATABASE_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_database():
    """Initialize the database schema."""
    with get_connection() as conn:
        cursor = conn.cursor()
        
        # Worlds table - tracks individual world instances hosted by this server
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS worlds (
                world_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                created_by TEXT,
                player_count INTEGER DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)
        
        # World ops table - world-specific operations log
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS world_ops (
                op_id INTEGER PRIMARY KEY AUTOINCREMENT,
                world_id TEXT NOT NULL,
                op_type TEXT NOT NULL,
                op_data TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (world_id) REFERENCES worlds(world_id) ON DELETE CASCADE
            )
        """)
        
        # Spells table - tracks spell identity and active revisions per channel
        # Spells are global (shared across all worlds)
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS spells (
                spell_id TEXT PRIMARY KEY,
                display_name TEXT,
                active_draft_rev TEXT,
                active_beta_rev TEXT,
                active_stable_rev TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)
        
        # Revisions table - immutable spell builds
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS revisions (
                revision_id TEXT PRIMARY KEY,
                spell_id TEXT NOT NULL,
                parent_revision_id TEXT,
                channel TEXT NOT NULL DEFAULT 'draft',
                version INTEGER NOT NULL DEFAULT 1,
                manifest_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (spell_id) REFERENCES spells(spell_id)
            )
        """)
        
        # Jobs table - build job tracking
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS jobs (
                job_id TEXT PRIMARY KEY,
                spell_id TEXT NOT NULL,
                draft_id TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                stage TEXT,
                progress_pct INTEGER DEFAULT 0,
                logs TEXT,
                error_message TEXT,
                result_revision_id TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (spell_id) REFERENCES spells(spell_id)
            )
        """)
        
        # Create indexes
        cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_worlds_name 
            ON worlds(name)
        """)
        cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_world_ops_world_id 
            ON world_ops(world_id)
        """)
        cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_revisions_spell_id 
            ON revisions(spell_id)
        """)
        cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_jobs_spell_id 
            ON jobs(spell_id)
        """)
        cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_jobs_status 
            ON jobs(status)
        """)
        
        print("[DB] Database initialized successfully")


# ============================================================================
# Spell CRUD
# ============================================================================

def create_spell(spell_id: str, display_name: str = None) -> Dict[str, Any]:
    """Create a new spell entry."""
    now = datetime.utcnow().isoformat()
    display_name = display_name or spell_id.replace("_", " ").title()
    
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO spells (spell_id, display_name, created_at, updated_at)
            VALUES (?, ?, ?, ?)
        """, (spell_id, display_name, now, now))
        
    return get_spell(spell_id)


def get_spell(spell_id: str) -> Optional[Dict[str, Any]]:
    """Get a spell by ID."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM spells WHERE spell_id = ?", (spell_id,))
        row = cursor.fetchone()
        return dict(row) if row else None


def get_all_spells() -> List[Dict[str, Any]]:
    """Get all spells."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM spells ORDER BY created_at DESC")
        return [dict(row) for row in cursor.fetchall()]


def update_spell_active_revision(spell_id: str, channel: str, revision_id: str) -> bool:
    """Update the active revision for a channel."""
    now = datetime.utcnow().isoformat()
    column = f"active_{channel}_rev"
    
    if column not in ["active_draft_rev", "active_beta_rev", "active_stable_rev"]:
        return False
    
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(f"""
            UPDATE spells 
            SET {column} = ?, updated_at = ?
            WHERE spell_id = ?
        """, (revision_id, now, spell_id))
        return cursor.rowcount > 0


def spell_exists(spell_id: str) -> bool:
    """Check if a spell exists."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT 1 FROM spells WHERE spell_id = ?", (spell_id,))
        return cursor.fetchone() is not None


# ============================================================================
# Revision CRUD
# ============================================================================

def create_revision(
    revision_id: str,
    spell_id: str,
    manifest: Dict[str, Any],
    channel: str = "draft",
    version: int = 1,
    parent_revision_id: str = None
) -> Dict[str, Any]:
    """Create a new revision entry."""
    now = datetime.utcnow().isoformat()
    manifest_json = json.dumps(manifest)
    
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO revisions 
            (revision_id, spell_id, parent_revision_id, channel, version, manifest_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (revision_id, spell_id, parent_revision_id, channel, version, manifest_json, now))
    
    return get_revision(revision_id)


def get_revision(revision_id: str) -> Optional[Dict[str, Any]]:
    """Get a revision by ID."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM revisions WHERE revision_id = ?", (revision_id,))
        row = cursor.fetchone()
        if row:
            result = dict(row)
            result["manifest"] = json.loads(result.pop("manifest_json"))
            return result
        return None


def get_spell_revisions(spell_id: str) -> List[Dict[str, Any]]:
    """Get all revisions for a spell."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT * FROM revisions 
            WHERE spell_id = ? 
            ORDER BY created_at DESC
        """, (spell_id,))
        results = []
        for row in cursor.fetchall():
            result = dict(row)
            result["manifest"] = json.loads(result.pop("manifest_json"))
            results.append(result)
        return results


def get_next_version(spell_id: str) -> int:
    """Get the next version number for a spell."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT MAX(version) as max_ver FROM revisions WHERE spell_id = ?
        """, (spell_id,))
        row = cursor.fetchone()
        max_ver = row["max_ver"] if row and row["max_ver"] else 0
        return max_ver + 1


# ============================================================================
# Job CRUD
# ============================================================================

def create_job(
    job_id: str,
    spell_id: str,
    draft_id: str = None
) -> Dict[str, Any]:
    """Create a new build job."""
    now = datetime.utcnow().isoformat()
    
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO jobs 
            (job_id, spell_id, draft_id, status, stage, progress_pct, created_at, updated_at)
            VALUES (?, ?, ?, 'pending', 'waiting', 0, ?, ?)
        """, (job_id, spell_id, draft_id, now, now))
    
    return get_job(job_id)


def get_job(job_id: str) -> Optional[Dict[str, Any]]:
    """Get a job by ID."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,))
        row = cursor.fetchone()
        return dict(row) if row else None


def update_job(
    job_id: str,
    status: str = None,
    stage: str = None,
    progress_pct: int = None,
    logs: str = None,
    error_message: str = None,
    result_revision_id: str = None
) -> bool:
    """Update job fields."""
    now = datetime.utcnow().isoformat()
    
    updates = ["updated_at = ?"]
    values = [now]
    
    if status is not None:
        updates.append("status = ?")
        values.append(status)
    if stage is not None:
        updates.append("stage = ?")
        values.append(stage)
    if progress_pct is not None:
        updates.append("progress_pct = ?")
        values.append(progress_pct)
    if logs is not None:
        updates.append("logs = ?")
        values.append(logs)
    if error_message is not None:
        updates.append("error_message = ?")
        values.append(error_message)
    if result_revision_id is not None:
        updates.append("result_revision_id = ?")
        values.append(result_revision_id)
    
    values.append(job_id)
    
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute(f"""
            UPDATE jobs SET {', '.join(updates)}
            WHERE job_id = ?
        """, values)
        return cursor.rowcount > 0


def get_pending_jobs() -> List[Dict[str, Any]]:
    """Get all pending jobs ordered by creation time."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT * FROM jobs 
            WHERE status = 'pending' 
            ORDER BY created_at ASC
        """)
        return [dict(row) for row in cursor.fetchall()]


def get_spell_jobs(spell_id: str, limit: int = 10) -> List[Dict[str, Any]]:
    """Get recent jobs for a spell."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT * FROM jobs 
            WHERE spell_id = ? 
            ORDER BY created_at DESC 
            LIMIT ?
        """, (spell_id, limit))
        return [dict(row) for row in cursor.fetchall()]


# ============================================================================
# World CRUD
# ============================================================================

def create_world(name: str, description: str = None, created_by: str = None) -> Dict[str, Any]:
    """Create a new world."""
    world_id = f"world_{uuid.uuid4().hex[:8]}"
    now = datetime.utcnow().isoformat()
    
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO worlds (world_id, name, description, created_by, player_count, created_at, updated_at)
            VALUES (?, ?, ?, ?, 0, ?, ?)
        """, (world_id, name, description, created_by, now, now))
    
    return get_world(world_id)


def get_world(world_id: str) -> Optional[Dict[str, Any]]:
    """Get a world by ID."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM worlds WHERE world_id = ?", (world_id,))
        row = cursor.fetchone()
        return dict(row) if row else None


def get_all_worlds() -> List[Dict[str, Any]]:
    """Get all worlds."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM worlds ORDER BY created_at DESC")
        return [dict(row) for row in cursor.fetchall()]


def update_world_player_count(world_id: str, delta: int) -> bool:
    """Update world player count by delta."""
    now = datetime.utcnow().isoformat()
    
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            UPDATE worlds 
            SET player_count = MAX(0, player_count + ?), updated_at = ?
            WHERE world_id = ?
        """, (delta, now, world_id))
        return cursor.rowcount > 0


def delete_world(world_id: str) -> bool:
    """Delete a world and its ops."""
    with get_connection() as conn:
        cursor = conn.cursor()
        # Delete ops first (cascade should handle but explicit is better)
        cursor.execute("DELETE FROM world_ops WHERE world_id = ?", (world_id,))
        cursor.execute("DELETE FROM worlds WHERE world_id = ?", (world_id,))
        return cursor.rowcount > 0


def world_exists(world_id: str) -> bool:
    """Check if a world exists."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT 1 FROM worlds WHERE world_id = ?", (world_id,))
        return cursor.fetchone() is not None


# ============================================================================
# World Ops CRUD
# ============================================================================

def add_world_op(world_id: str, op_type: str, op_data: Dict[str, Any]) -> int:
    """Add an operation to a world."""
    now = datetime.utcnow().isoformat()
    op_json = json.dumps(op_data)
    
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO world_ops (world_id, op_type, op_data, created_at)
            VALUES (?, ?, ?, ?)
        """, (world_id, op_type, op_json, now))
        return cursor.lastrowid


def get_world_ops(world_id: str) -> List[Dict[str, Any]]:
    """Get all operations for a world."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT * FROM world_ops 
            WHERE world_id = ? 
            ORDER BY op_id ASC
        """, (world_id,))
        results = []
        for row in cursor.fetchall():
            result = dict(row)
            result["op_data"] = json.loads(result["op_data"])
            results.append(result)
        return results


def clear_world_ops(world_id: str) -> int:
    """Clear all operations for a world. Returns count of deleted ops."""
    with get_connection() as conn:
        cursor = conn.cursor()
        cursor.execute("DELETE FROM world_ops WHERE world_id = ?", (world_id,))
        return cursor.rowcount


# Initialize on import
if __name__ == "__main__":
    init_database()
    print("Database initialized!")
