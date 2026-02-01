"""
Build job worker for spell package creation.
Processes jobs through stages and emits progress via callbacks.
"""

import time
import uuid
import threading
from typing import Optional, Dict, Any, Callable, List
from datetime import datetime

from database import (
    get_job, update_job, get_pending_jobs,
    create_revision, get_next_version, update_spell_active_revision
)
from spell_storage import (
    create_revision_directory, write_revision_file_text,
    write_manifest, create_manifest
)


# Build stages
STAGES = ["prepare", "assemble_package", "validate", "finalize"]


class BuildJobWorker:
    """
    Background worker that processes spell build jobs.
    Each job goes through stages: prepare -> assemble_package -> validate -> finalize
    """
    
    def __init__(self, progress_callback: Callable[[str, str, int, str, Dict], None] = None):
        """
        Initialize the worker.
        
        Args:
            progress_callback: Function(job_id, stage, pct, message, extras) 
                              called when job progress updates
        """
        self.progress_callback = progress_callback
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._job_queue: List[Dict[str, Any]] = []
        self._lock = threading.Lock()
    
    def start(self):
        """Start the background worker thread."""
        if self._running:
            return
        
        self._running = True
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()
        print("[JobWorker] Started background worker thread")
    
    def stop(self):
        """Stop the background worker."""
        self._running = False
        if self._thread:
            self._thread.join(timeout=5)
            self._thread = None
        print("[JobWorker] Stopped background worker")
    
    def enqueue_job(self, job_id: str, build_options: Dict[str, Any] = None):
        """Add a job to the processing queue."""
        with self._lock:
            self._job_queue.append({
                "job_id": job_id,
                "options": build_options or {}
            })
        print(f"[JobWorker] Enqueued job {job_id}")
    
    def _run_loop(self):
        """Main worker loop."""
        while self._running:
            job_entry = None
            
            with self._lock:
                if self._job_queue:
                    job_entry = self._job_queue.pop(0)
            
            if job_entry:
                try:
                    self._process_job(job_entry["job_id"], job_entry["options"])
                except Exception as e:
                    print(f"[JobWorker] Job {job_entry['job_id']} failed: {e}")
                    update_job(
                        job_entry["job_id"],
                        status="failed",
                        error_message=str(e)
                    )
                    self._emit_progress(job_entry["job_id"], "error", 0, f"Build failed: {e}", {})
            else:
                # No jobs in queue, sleep briefly
                time.sleep(0.5)
    
    def _emit_progress(self, job_id: str, stage: str, pct: int, message: str, extras: Dict = None):
        """Emit progress update via callback."""
        if self.progress_callback:
            self.progress_callback(job_id, stage, pct, message, extras or {})
    
    def _process_job(self, job_id: str, options: Dict[str, Any]):
        """Process a single build job through all stages."""
        job = get_job(job_id)
        if not job:
            print(f"[JobWorker] Job {job_id} not found")
            return
        
        spell_id = job["spell_id"]
        print(f"[JobWorker] Processing job {job_id} for spell {spell_id}")
        
        update_job(job_id, status="running", stage="prepare", progress_pct=0)
        self._emit_progress(job_id, "prepare", 0, "Starting build...", {})
        
        # Stage 1: Prepare
        self._stage_prepare(job_id, spell_id, options)
        
        # Stage 2: Assemble Package
        revision_id, code_files, asset_files = self._stage_assemble(job_id, spell_id, options)
        
        # Stage 3: Validate
        self._stage_validate(job_id, spell_id, revision_id, options)
        
        # Stage 4: Finalize
        manifest = self._stage_finalize(job_id, spell_id, revision_id, code_files, asset_files, options)
        
        # Complete
        update_job(
            job_id,
            status="completed",
            stage="done",
            progress_pct=100,
            result_revision_id=revision_id
        )
        
        self._emit_progress(job_id, "done", 100, "Build complete!", {
            "revision_id": revision_id,
            "manifest": manifest
        })
        
        print(f"[JobWorker] Job {job_id} completed, revision: {revision_id}")
    
    def _stage_prepare(self, job_id: str, spell_id: str, options: Dict):
        """Prepare stage - setup and initialization."""
        update_job(job_id, stage="prepare", progress_pct=5)
        self._emit_progress(job_id, "prepare", 5, "Preparing build environment...", {})
        
        # Simulate some preparation work
        time.sleep(0.2)
        
        update_job(job_id, progress_pct=15)
        self._emit_progress(job_id, "prepare", 15, "Build environment ready", {})
    
    def _stage_assemble(self, job_id: str, spell_id: str, options: Dict) -> tuple:
        """Assemble package stage - write code and assets."""
        update_job(job_id, stage="assemble_package", progress_pct=20)
        self._emit_progress(job_id, "assemble_package", 20, "Assembling package files...", {})
        
        # Generate revision ID
        version = get_next_version(spell_id)
        revision_id = f"rev_{version:06d}_{uuid.uuid4().hex[:8]}"
        
        # Create revision directory
        create_revision_directory(spell_id, revision_id)
        
        update_job(job_id, progress_pct=30)
        self._emit_progress(job_id, "assemble_package", 30, f"Created revision {revision_id}", {})
        
        # Get code content from options or generate stub
        code_content = options.get("code", self._generate_stub_spell(spell_id))
        
        # Write main spell script
        code_info = write_revision_file_text(
            spell_id, revision_id, "code/spell.gd", code_content
        )
        code_files = [code_info]
        
        update_job(job_id, progress_pct=45)
        self._emit_progress(job_id, "assemble_package", 45, "Wrote spell script", {})
        
        # Write assets (from options or generate placeholders)
        asset_files = []
        
        # Icon asset
        icon_data = options.get("icon_data")
        if icon_data:
            icon_info = write_revision_file_text(
                spell_id, revision_id, "assets/icon.png", icon_data
            )
            asset_files.append(icon_info)
        else:
            # Create a placeholder icon reference
            placeholder_icon = self._generate_placeholder_icon()
            from spell_storage import write_revision_file
            icon_info = write_revision_file(
                spell_id, revision_id, "assets/icon.png", placeholder_icon
            )
            asset_files.append(icon_info)
        
        update_job(job_id, progress_pct=55)
        self._emit_progress(job_id, "assemble_package", 55, "Wrote asset files", {})
        
        return revision_id, code_files, asset_files
    
    def _stage_validate(self, job_id: str, spell_id: str, revision_id: str, options: Dict):
        """Validate stage - check spell interface implementation."""
        update_job(job_id, stage="validate", progress_pct=60)
        self._emit_progress(job_id, "validate", 60, "Validating spell interface...", {})
        
        # Read the spell script and check for required methods
        from spell_storage import read_revision_file
        code_bytes = read_revision_file(spell_id, revision_id, "code/spell.gd")
        
        if not code_bytes:
            raise ValueError("Spell script not found")
        
        code_content = code_bytes.decode("utf-8")
        
        # Check for required interface methods
        required_methods = ["on_cast"]
        optional_methods = ["on_tick", "on_cancel", "on_event", "get_manifest"]
        
        missing = []
        for method in required_methods:
            if f"func {method}" not in code_content:
                missing.append(method)
        
        if missing:
            raise ValueError(f"Missing required methods: {', '.join(missing)}")
        
        update_job(job_id, progress_pct=75)
        self._emit_progress(job_id, "validate", 75, "Validation passed", {})
    
    def _stage_finalize(
        self, 
        job_id: str, 
        spell_id: str, 
        revision_id: str,
        code_files: List[Dict],
        asset_files: List[Dict],
        options: Dict
    ) -> Dict:
        """Finalize stage - compute hashes and write manifest."""
        update_job(job_id, stage="finalize", progress_pct=80)
        self._emit_progress(job_id, "finalize", 80, "Computing file hashes...", {})
        
        # Get version and metadata
        version = get_next_version(spell_id)
        
        metadata = options.get("metadata", {})
        if not metadata.get("name"):
            metadata["name"] = spell_id.replace("_", " ").title()
        if not metadata.get("description"):
            metadata["description"] = options.get("prompt", f"A spell: {spell_id}")
        metadata.setdefault("tags", [])
        metadata.setdefault("preview_icon", "assets/icon.png")
        
        # Create manifest
        manifest = create_manifest(
            spell_id=spell_id,
            revision_id=revision_id,
            version=version,
            entrypoint="code/spell.gd",
            metadata=metadata,
            code_files=code_files,
            asset_files=asset_files
        )
        
        update_job(job_id, progress_pct=90)
        self._emit_progress(job_id, "finalize", 90, "Writing manifest...", {})
        
        # Write manifest to disk
        write_manifest(spell_id, revision_id, manifest)
        
        # Create revision in database
        create_revision(
            revision_id=revision_id,
            spell_id=spell_id,
            manifest=manifest,
            channel="draft",
            version=version,
            parent_revision_id=options.get("parent_revision_id")
        )
        
        # Auto-set as draft active
        update_spell_active_revision(spell_id, "draft", revision_id)
        
        update_job(job_id, progress_pct=95)
        self._emit_progress(job_id, "finalize", 95, "Manifest written", {"manifest": manifest})
        
        return manifest
    
    def _generate_stub_spell(self, spell_id: str) -> str:
        """Generate a stub spell script that implements the interface."""
        return f'''extends SpellModule
## Auto-generated spell: {spell_id}

func get_manifest() -> Dictionary:
    return {{
        "spell_id": "{spell_id}",
        "name": "{spell_id.replace("_", " ").title()}"
    }}


func on_cast(ctx: SpellContext) -> void:
    print("[{spell_id}] Spell cast by: ", ctx.caster_id)
    print("[{spell_id}] Target position: ", ctx.target_position)
    
    # Spawn a visual effect
    if ctx.world:
        ctx.world.play_vfx("default_cast", ctx.target_position)


func on_tick(ctx: SpellContext, dt: float) -> void:
    pass  # Optional tick logic


func on_cancel(ctx: SpellContext) -> void:
    print("[{spell_id}] Spell cancelled")
'''
    
    def _generate_placeholder_icon(self) -> bytes:
        """Generate a minimal placeholder PNG icon (1x1 magenta pixel)."""
        # Minimal valid PNG: 1x1 pixel, magenta color
        # This is a real 1x1 PNG file
        return bytes([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  # PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,  # IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  # 1x1
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,  # IDAT chunk
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x18, 0xDD,
            0x8D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,  # IEND chunk
            0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ])


# Singleton instance for the worker
_worker_instance: Optional[BuildJobWorker] = None


def get_worker() -> BuildJobWorker:
    """Get or create the singleton worker instance."""
    global _worker_instance
    if _worker_instance is None:
        _worker_instance = BuildJobWorker()
    return _worker_instance


def start_worker(progress_callback: Callable = None):
    """Start the singleton worker with optional progress callback."""
    worker = get_worker()
    if progress_callback:
        worker.progress_callback = progress_callback
    worker.start()
    return worker


def stop_worker():
    """Stop the singleton worker."""
    global _worker_instance
    if _worker_instance:
        _worker_instance.stop()
        _worker_instance = None
