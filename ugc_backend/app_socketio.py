"""
UGC World Backend Server with Spell Package System

A Flask + Socket.IO server that handles:
- Client connections
- Spell package creation, building, and distribution
- Build job progress streaming
- Multiplayer spell casting synchronization
- Legacy world ops (create_land, dig)

Run with: python app_socketio.py
"""

import os
import uuid
import json
import logging
from datetime import datetime
from typing import Dict, Any, Set
from flask import Flask, request, send_file
from flask_socketio import SocketIO, emit, join_room, leave_room

# Local imports
from database import (
    init_database,
    create_spell, get_spell, get_all_spells, spell_exists,
    update_spell_active_revision, get_spell_revisions,
    create_job, get_job, update_job,
    get_revision
)
from spell_storage import (
    read_revision_file, read_manifest, revision_exists,
    get_revision_dir, list_revision_files
)
from job_worker import start_worker, get_worker

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)
logger = logging.getLogger(__name__)

# Flask app setup
app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'dev-secret-key-change-in-prod')

# Socket.IO setup with CORS for development
socketio = SocketIO(
    app,
    cors_allowed_origins="*",
    async_mode='threading',
    ping_timeout=60,
    ping_interval=25
)

# Server state
connected_clients: Set[str] = set()
op_log: list[dict] = []  # Legacy world ops


# ============================================================================
# Job Progress Callback
# ============================================================================

def on_job_progress(job_id: str, stage: str, pct: int, message: str, extras: Dict):
    """Callback from job worker to emit progress via Socket.IO."""
    payload = {
        "job_id": job_id,
        "stage": stage,
        "pct": pct,
        "message": message
    }
    
    # Add manifest/revision info if available
    if extras.get("revision_id"):
        payload["revision_id"] = extras["revision_id"]
    if extras.get("manifest"):
        payload["manifest"] = extras["manifest"]
    
    socketio.emit("job.progress", payload)
    logger.info(f"[Job {job_id}] {stage} {pct}% - {message}")


# ============================================================================
# Socket.IO Connection Events
# ============================================================================

@socketio.on('connect')
def handle_connect():
    """Handle client connection."""
    client_id = request.sid
    connected_clients.add(client_id)
    logger.info(f"Client connected: {client_id}. Total: {len(connected_clients)}")
    
    # Send connection acknowledgment
    emit('connected', {
        'client_id': client_id,
        'server_time': datetime.utcnow().isoformat()
    })
    
    # Send initial sync for legacy world ops
    if op_log:
        emit('sync_ops', {'ops': op_log})
    else:
        emit('sync_complete', {'message': 'World is empty'})


@socketio.on('disconnect')
def handle_disconnect():
    """Handle client disconnection."""
    client_id = request.sid
    connected_clients.discard(client_id)
    logger.info(f"Client disconnected: {client_id}. Total: {len(connected_clients)}")


# ============================================================================
# Spell Management Events
# ============================================================================

@socketio.on('spell.create_draft')
def handle_create_draft(data: Dict[str, Any]):
    """
    Create a new spell draft.
    
    Input: { spell_id?: string }
    Output: { spell_id: string, created: bool }
    """
    spell_id = data.get('spell_id')
    
    # Generate spell_id if not provided
    if not spell_id:
        spell_id = f"spell_{uuid.uuid4().hex[:8]}"
    
    # Create spell if it doesn't exist
    created = False
    if not spell_exists(spell_id):
        create_spell(spell_id)
        created = True
        logger.info(f"Created new spell: {spell_id}")
    
    spell = get_spell(spell_id)
    
    emit('spell.draft_created', {
        'spell_id': spell_id,
        'created': created,
        'spell': spell
    })


@socketio.on('spell.start_build')
def handle_start_build(data: Dict[str, Any]):
    """
    Start a build job for a spell.
    
    Input: {
        spell_id: string,
        prompt?: string,
        code?: string,
        options?: {
            parent_revision_id?: string,
            metadata?: { name?, description?, tags? }
        }
    }
    Output: { job_id: string, spell_id: string }
    """
    spell_id = data.get('spell_id')
    if not spell_id:
        emit('error', {'message': 'spell_id is required'})
        return
    
    # Ensure spell exists
    if not spell_exists(spell_id):
        create_spell(spell_id)
    
    # Create job
    job_id = f"job_{uuid.uuid4().hex[:12]}"
    create_job(job_id, spell_id)
    
    # Prepare build options
    build_options = {
        'prompt': data.get('prompt', ''),
        'code': data.get('code'),  # None means generate stub
        'parent_revision_id': data.get('options', {}).get('parent_revision_id'),
        'metadata': data.get('options', {}).get('metadata', {})
    }
    
    # Enqueue job for processing
    worker = get_worker()
    worker.enqueue_job(job_id, build_options)
    
    logger.info(f"Started build job {job_id} for spell {spell_id}")
    
    emit('spell.build_started', {
        'job_id': job_id,
        'spell_id': spell_id
    })


@socketio.on('spell.publish')
def handle_publish(data: Dict[str, Any]):
    """
    Publish a revision to a channel.
    
    Input: { spell_id: string, revision_id: string, channel: string }
    Output: broadcasts spell.active_update to all clients
    """
    spell_id = data.get('spell_id')
    revision_id = data.get('revision_id')
    channel = data.get('channel', 'beta')
    
    if not spell_id or not revision_id:
        emit('error', {'message': 'spell_id and revision_id are required'})
        return
    
    if channel not in ['draft', 'beta', 'stable']:
        emit('error', {'message': 'channel must be draft, beta, or stable'})
        return
    
    # Verify revision exists
    if not revision_exists(spell_id, revision_id):
        emit('error', {'message': f'Revision {revision_id} not found'})
        return
    
    # Update active revision
    update_spell_active_revision(spell_id, channel, revision_id)
    
    # Get manifest for broadcast
    manifest = read_manifest(spell_id, revision_id)
    
    logger.info(f"Published {spell_id} revision {revision_id} to {channel}")
    
    # Broadcast to all connected clients
    socketio.emit('spell.active_update', {
        'spell_id': spell_id,
        'revision_id': revision_id,
        'channel': channel,
        'manifest': manifest
    })
    
    # Also emit revision ready to help clients know they may need to download
    socketio.emit('spell.revision_ready', {
        'spell_id': spell_id,
        'revision_id': revision_id,
        'manifest': manifest
    })


@socketio.on('spell.list')
def handle_list_spells(data: Dict[str, Any]):
    """
    List all spells.
    
    Output: { spells: [...] }
    """
    spells = get_all_spells()
    emit('spell.list_result', {'spells': spells})


@socketio.on('spell.get_revisions')
def handle_get_revisions(data: Dict[str, Any]):
    """
    Get all revisions for a spell.
    
    Input: { spell_id: string }
    Output: { spell_id: string, revisions: [...] }
    """
    spell_id = data.get('spell_id')
    if not spell_id:
        emit('error', {'message': 'spell_id is required'})
        return
    
    revisions = get_spell_revisions(spell_id)
    emit('spell.revisions_result', {
        'spell_id': spell_id,
        'revisions': revisions
    })


# ============================================================================
# Content Distribution Events
# ============================================================================

@socketio.on('content.get_manifest')
def handle_get_manifest(data: Dict[str, Any]):
    """
    Get manifest for a specific revision.
    
    Input: { spell_id: string, revision_id: string }
    Output: { spell_id: string, revision_id: string, manifest: {...} }
    """
    spell_id = data.get('spell_id')
    revision_id = data.get('revision_id')
    
    if not spell_id or not revision_id:
        emit('error', {'message': 'spell_id and revision_id are required'})
        return
    
    manifest = read_manifest(spell_id, revision_id)
    
    if not manifest:
        emit('error', {'message': f'Manifest not found for {spell_id}/{revision_id}'})
        return
    
    emit('content.manifest', {
        'spell_id': spell_id,
        'revision_id': revision_id,
        'manifest': manifest
    })


@socketio.on('content.get_file')
def handle_get_file(data: Dict[str, Any]):
    """
    Get a specific file from a revision.
    
    Input: { spell_id: string, revision_id: string, path: string }
    Output: { spell_id: string, revision_id: string, path: string, content: base64 }
    """
    import base64
    
    spell_id = data.get('spell_id')
    revision_id = data.get('revision_id')
    path = data.get('path')
    
    if not all([spell_id, revision_id, path]):
        emit('error', {'message': 'spell_id, revision_id, and path are required'})
        return
    
    content = read_revision_file(spell_id, revision_id, path)
    
    if content is None:
        emit('error', {'message': f'File not found: {path}'})
        return
    
    emit('content.file', {
        'spell_id': spell_id,
        'revision_id': revision_id,
        'path': path,
        'content': base64.b64encode(content).decode('ascii'),
        'size': len(content)
    })


@socketio.on('content.list_files')
def handle_list_files(data: Dict[str, Any]):
    """
    List all files in a revision.
    
    Input: { spell_id: string, revision_id: string }
    Output: { spell_id: string, revision_id: string, files: [...] }
    """
    spell_id = data.get('spell_id')
    revision_id = data.get('revision_id')
    
    if not spell_id or not revision_id:
        emit('error', {'message': 'spell_id and revision_id are required'})
        return
    
    files = list_revision_files(spell_id, revision_id)
    
    emit('content.files_list', {
        'spell_id': spell_id,
        'revision_id': revision_id,
        'files': files
    })


# ============================================================================
# Multiplayer Casting Events
# ============================================================================

@socketio.on('spell.cast_request')
def handle_cast_request(data: Dict[str, Any]):
    """
    Handle a spell cast request from a client.
    Server validates and broadcasts to all clients.
    
    Input: {
        spell_id: string,
        revision_id: string,
        cast_params: { target_position: {x,y,z}, ... }
    }
    Output: broadcasts spell.cast_event to all clients
    """
    spell_id = data.get('spell_id')
    revision_id = data.get('revision_id')
    cast_params = data.get('cast_params', {})
    
    if not spell_id:
        emit('error', {'message': 'spell_id is required'})
        return
    
    # Light validation: check spell exists
    if not spell_exists(spell_id):
        emit('spell.cast_rejected', {
            'spell_id': spell_id,
            'error': 'Spell not found'
        })
        return
    
    # If no revision specified, use active beta or stable
    if not revision_id:
        spell = get_spell(spell_id)
        revision_id = spell.get('active_beta_rev') or spell.get('active_stable_rev')
    
    if not revision_id:
        emit('spell.cast_rejected', {
            'spell_id': spell_id,
            'error': 'No active revision found'
        })
        return
    
    # Generate deterministic seed for this cast
    import random
    cast_seed = random.randint(0, 2**31 - 1)
    
    caster_id = request.sid
    
    logger.info(f"Cast: {spell_id} rev {revision_id} by {caster_id}")
    
    # Broadcast cast event to all clients (including sender)
    socketio.emit('spell.cast_event', {
        'spell_id': spell_id,
        'revision_id': revision_id,
        'caster_id': caster_id,
        'cast_params': cast_params,
        'seed': cast_seed,
        'timestamp': datetime.utcnow().isoformat()
    })


# ============================================================================
# Legacy World Ops (for backward compatibility)
# ============================================================================

@socketio.on('request_spell')
def handle_legacy_spell(data: Dict[str, Any]):
    """Handle legacy spell requests (create_land, dig)."""
    spell = data.get('spell', {})
    spell_type = spell.get('type', '')
    
    if spell_type not in ['create_land', 'dig']:
        emit('spell_rejected', {'error': f'Unknown spell type: {spell_type}'})
        return
    
    # Compile to ops
    ops = []
    if spell_type == 'create_land':
        ops.append({
            'op': 'add_sphere',
            'center': spell.get('center', {'x': 0, 'y': 0, 'z': 0}),
            'radius': float(spell.get('radius', 8.0)),
            'material_id': int(spell.get('material_id', 1))
        })
    elif spell_type == 'dig':
        ops.append({
            'op': 'subtract_sphere',
            'center': spell.get('center', {'x': 0, 'y': 0, 'z': 0}),
            'radius': float(spell.get('radius', 6.0))
        })
    
    # Apply and broadcast
    for op in ops:
        op_log.append(op)
        logger.info(f"Broadcasting op: {op['op']} at {op.get('center', 'unknown')}")
        socketio.emit('apply_op', {'op': op})


@socketio.on('ping')
def handle_ping(data: Dict[str, Any] = None):
    """Handle ping request."""
    emit('pong', {
        'clients': len(connected_clients),
        'ops': len(op_log)
    })


@socketio.on('clear_world')
def handle_clear_world(data: Dict[str, Any] = None):
    """Handle world clear request."""
    op_log.clear()
    logger.info("World cleared")
    socketio.emit('world_cleared', {})


# ============================================================================
# HTTP Endpoints (for direct file downloads if needed)
# ============================================================================

@app.route('/api/health')
def health():
    """Health check endpoint."""
    return {'status': 'ok', 'clients': len(connected_clients)}


@app.route('/api/spells')
def api_list_spells():
    """List all spells."""
    return {'spells': get_all_spells()}


@app.route('/api/spells/<spell_id>/revisions/<revision_id>/files/<path:file_path>')
def api_get_file(spell_id: str, revision_id: str, file_path: str):
    """Download a file from a revision."""
    import os
    
    revision_dir = get_revision_dir(spell_id, revision_id)
    full_path = os.path.join(revision_dir, file_path)
    
    if not os.path.exists(full_path):
        return {'error': 'File not found'}, 404
    
    return send_file(full_path)


# ============================================================================
# Main Entry Point
# ============================================================================

def main():
    """Start the server."""
    print("=" * 60)
    print("UGC World Backend Server (Socket.IO)")
    print("=" * 60)
    
    # Initialize database
    init_database()
    
    # Start job worker with progress callback
    start_worker(on_job_progress)
    
    host = os.environ.get('HOST', '0.0.0.0')
    port = int(os.environ.get('PORT', 5000))
    
    print(f"Socket.IO server starting on http://{host}:{port}")
    print("=" * 60)
    
    socketio.run(app, host=host, port=port, debug=False, allow_unsafe_werkzeug=True)


if __name__ == '__main__':
    main()
