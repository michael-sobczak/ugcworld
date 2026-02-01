"""
Database module for spell package system.
Uses SQLite for metadata storage.
"""

import sqlite3
import json
import os
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
        
        # Spells table - tracks spell identity and active revisions per channel
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


# Initialize on import
if __name__ == "__main__":
    init_database()
    print("Database initialized!")
