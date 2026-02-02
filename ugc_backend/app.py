"""
UGC World Backend Server with Spell Package System

An async WebSocket server that handles:
- Client connections
- Spell package creation, building, and distribution
- Build job progress streaming
- Multiplayer spell casting synchronization
- Legacy world ops (create_land, dig)

Run with: python app.py
"""

import asyncio
import websockets
from http import HTTPStatus
import json
import logging
import uuid
import base64
import threading
import os
from datetime import datetime
from typing import Dict, Any, Set

# Local imports
from database import (
    init_database,
    # Spell functions
    create_spell, get_spell, get_all_spells, spell_exists,
    update_spell_active_revision, get_spell_revisions,
    create_job, get_job, update_job,
    get_revision,
    # World functions
    create_world, get_world, get_all_worlds, world_exists,
    update_world_player_count, delete_world,
    add_world_op, get_world_ops, clear_world_ops
)
from spell_storage import (
    read_revision_file, read_manifest, revision_exists,
    get_revision_dir, list_revision_files
)
from job_worker import BuildJobWorker, start_worker, get_worker

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)
logger = logging.getLogger(__name__)

# Server configuration (from environment or defaults)
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "5000"))

# Server state
connected_clients: Set[websockets.WebSocketServerProtocol] = set()
client_worlds: Dict[websockets.WebSocketServerProtocol, str] = {}  # client -> world_id mapping

# Event loop reference for cross-thread communication
main_loop: asyncio.AbstractEventLoop = None


# ============================================================================
# HTTP Health Check Handler (websockets 12+ API)
# ============================================================================

def process_request(connection, request):
    """
    Handle HTTP requests before WebSocket upgrade.
    Uses connection.respond() for health checks, returns None for WebSocket.
    
    This is called by websockets.serve() for every incoming connection.
    For health check endpoints, we respond with HTTP 200 directly.
    For WebSocket connections, we return None to continue the handshake.
    """
    # Health check endpoints - respond to plain HTTP requests
    if request.path in ("/health", "/api/health", "/healthz"):
        # Check if this is NOT a WebSocket upgrade request
        upgrade_header = request.headers.get("Upgrade", "")
        if upgrade_header.lower() != "websocket":
            # Use connection.respond() to send HTTP response
            body = json.dumps({
                "status": "ok",
                "clients": len(connected_clients),
                "server": "ugc-world-backend"
            })
            return connection.respond(HTTPStatus.OK, body)
    
    # Continue with WebSocket handshake
    return None


# ============================================================================
# Broadcasting
# ============================================================================

async def broadcast(message: dict, exclude: websockets.WebSocketServerProtocol = None):
    """Broadcast a message to all connected clients."""
    if not connected_clients:
        return
    
    msg_str = json.dumps(message)
    tasks = []
    for client in connected_clients:
        if client != exclude:
            tasks.append(asyncio.create_task(client.send(msg_str)))
    
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)


async def broadcast_to_world(world_id: str, message: dict, exclude: websockets.WebSocketServerProtocol = None):
    """Broadcast a message to all clients in a specific world."""
    if not connected_clients:
        return
    
    msg_str = json.dumps(message)
    tasks = []
    for client in connected_clients:
        if client != exclude and client_worlds.get(client) == world_id:
            tasks.append(asyncio.create_task(client.send(msg_str)))
    
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)


def broadcast_sync(message: dict):
    """Thread-safe broadcast (called from job worker thread)."""
    global main_loop
    if main_loop:
        asyncio.run_coroutine_threadsafe(broadcast(message), main_loop)


async def send_to_client(websocket: websockets.WebSocketServerProtocol, message: dict):
    """Send a message to a specific client."""
    try:
        await websocket.send(json.dumps(message))
    except Exception as e:
        logger.warning(f"Failed to send message: {e}")


# ============================================================================
# Job Progress Callback
# ============================================================================

def on_job_progress(job_id: str, stage: str, pct: int, message: str, extras: Dict):
    """Callback from job worker to broadcast progress."""
    payload = {
        "type": "job.progress",
        "job_id": job_id,
        "stage": stage,
        "pct": pct,
        "message": message
    }
    
    if extras.get("revision_id"):
        payload["revision_id"] = extras["revision_id"]
    if extras.get("manifest"):
        payload["manifest"] = extras["manifest"]
    
    logger.info(f"[Job {job_id}] {stage} {pct}% - {message}")
    broadcast_sync(payload)


# ============================================================================
# Message Handlers
# ============================================================================

async def handle_message(websocket: websockets.WebSocketServerProtocol, message: str):
    """Route incoming messages to appropriate handlers."""
    try:
        data = json.loads(message)
    except json.JSONDecodeError:
        logger.warning(f"Invalid JSON received: {message[:100]}")
        return
    
    msg_type = data.get("type", "")
    
    # Route to handler
    handlers = {
        # World management
        "world.list": handle_list_worlds,
        "world.create": handle_create_world,
        "world.join": handle_join_world,
        "world.leave": handle_leave_world,
        "world.get": handle_get_world,
        
        # Spell management
        "spell.create_draft": handle_create_draft,
        "spell.start_build": handle_start_build,
        "spell.publish": handle_publish,
        "spell.list": handle_list_spells,
        "spell.get_revisions": handle_get_revisions,
        "spell.cast_request": handle_cast_request,
        
        # Content distribution
        "content.get_manifest": handle_get_manifest,
        "content.get_file": handle_get_file,
        "content.list_files": handle_list_files,
        
        # Legacy world ops
        "request_spell": handle_legacy_spell,
        "ping": handle_ping,
        "clear_world": handle_clear_world,
    }
    
    handler = handlers.get(msg_type)
    if handler:
        await handler(websocket, data)
    else:
        logger.warning(f"Unknown message type: {msg_type}")


# ============================================================================
# World Management Handlers
# ============================================================================

async def handle_list_worlds(websocket, data: Dict[str, Any]):
    """List all available worlds."""
    worlds = get_all_worlds()
    await send_to_client(websocket, {'type': 'world.list_result', 'worlds': worlds})


async def handle_create_world(websocket, data: Dict[str, Any]):
    """Create a new world."""
    name = data.get('name', '').strip()
    description = data.get('description', '')
    
    if not name:
        await send_to_client(websocket, {'type': 'error', 'message': 'World name is required'})
        return
    
    if len(name) > 50:
        await send_to_client(websocket, {'type': 'error', 'message': 'World name must be 50 characters or less'})
        return
    
    client_id = str(id(websocket))
    world = create_world(name, description, client_id)
    
    logger.info(f"World created: {world['world_id']} '{name}' by {client_id}")
    
    await send_to_client(websocket, {'type': 'world.created', 'world': world})
    
    # Broadcast updated world list to all clients
    await broadcast({'type': 'world.list_updated', 'worlds': get_all_worlds()})


async def handle_join_world(websocket, data: Dict[str, Any]):
    """Join a world."""
    world_id = data.get('world_id')
    
    if not world_id:
        await send_to_client(websocket, {'type': 'error', 'message': 'world_id is required'})
        return
    
    # Check world exists
    world = get_world(world_id)
    if not world:
        await send_to_client(websocket, {'type': 'error', 'message': f'World {world_id} not found'})
        return
    
    # Leave current world if in one
    current_world = client_worlds.get(websocket)
    if current_world:
        update_world_player_count(current_world, -1)
        logger.info(f"Client left world {current_world}")
    
    # Join the new world
    client_worlds[websocket] = world_id
    update_world_player_count(world_id, 1)
    
    logger.info(f"Client joined world {world_id}")
    
    # Send join confirmation
    world = get_world(world_id)  # Re-fetch to get updated player count
    await send_to_client(websocket, {
        'type': 'world.joined',
        'world_id': world_id,
        'world': world
    })
    
    # Send world ops for sync
    ops = get_world_ops(world_id)
    if ops:
        # Convert to op format expected by client
        op_list = []
        for op_record in ops:
            op_data = op_record['op_data']
            op_data['op'] = op_record['op_type']
            op_list.append(op_data)
        await send_to_client(websocket, {'type': 'sync_ops', 'ops': op_list})
    else:
        await send_to_client(websocket, {'type': 'sync_complete', 'message': 'World is empty'})


async def handle_leave_world(websocket, data: Dict[str, Any]):
    """Leave the current world."""
    world_id = client_worlds.pop(websocket, None)
    
    if world_id:
        update_world_player_count(world_id, -1)
        logger.info(f"Client left world {world_id}")
        await send_to_client(websocket, {'type': 'world.left', 'left_world_id': world_id})
    else:
        await send_to_client(websocket, {'type': 'world.left', 'left_world_id': None})


async def handle_get_world(websocket, data: Dict[str, Any]):
    """Get details of a specific world."""
    world_id = data.get('world_id')
    
    if not world_id:
        await send_to_client(websocket, {'type': 'error', 'message': 'world_id is required'})
        return
    
    world = get_world(world_id)
    if not world:
        await send_to_client(websocket, {'type': 'error', 'message': f'World {world_id} not found'})
        return
    
    await send_to_client(websocket, {'type': 'world.info', 'world': world})


# ============================================================================
# Spell Management Handlers
# ============================================================================

async def handle_create_draft(websocket, data: Dict[str, Any]):
    """Create a new spell draft."""
    spell_id = data.get('spell_id')
    
    if not spell_id:
        spell_id = f"spell_{uuid.uuid4().hex[:8]}"
    
    created = False
    if not spell_exists(spell_id):
        create_spell(spell_id)
        created = True
        logger.info(f"Created new spell: {spell_id}")
    
    spell = get_spell(spell_id)
    
    await send_to_client(websocket, {
        'type': 'spell.draft_created',
        'spell_id': spell_id,
        'created': created,
        'spell': spell
    })


async def handle_start_build(websocket, data: Dict[str, Any]):
    """Start a build job for a spell."""
    spell_id = data.get('spell_id')
    if not spell_id:
        await send_to_client(websocket, {'type': 'error', 'message': 'spell_id is required'})
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
        'code': data.get('code'),
        'parent_revision_id': data.get('options', {}).get('parent_revision_id'),
        'metadata': data.get('options', {}).get('metadata', {})
    }
    
    # Enqueue job
    worker = get_worker()
    worker.enqueue_job(job_id, build_options)
    
    logger.info(f"Started build job {job_id} for spell {spell_id}")
    
    await send_to_client(websocket, {
        'type': 'spell.build_started',
        'job_id': job_id,
        'spell_id': spell_id
    })


async def handle_publish(websocket, data: Dict[str, Any]):
    """Publish a revision to a channel."""
    spell_id = data.get('spell_id')
    revision_id = data.get('revision_id')
    channel = data.get('channel', 'beta')
    
    if not spell_id or not revision_id:
        await send_to_client(websocket, {'type': 'error', 'message': 'spell_id and revision_id required'})
        return
    
    if channel not in ['draft', 'beta', 'stable']:
        await send_to_client(websocket, {'type': 'error', 'message': 'Invalid channel'})
        return
    
    if not revision_exists(spell_id, revision_id):
        await send_to_client(websocket, {'type': 'error', 'message': 'Revision not found'})
        return
    
    update_spell_active_revision(spell_id, channel, revision_id)
    manifest = read_manifest(spell_id, revision_id)
    
    logger.info(f"Published {spell_id} revision {revision_id} to {channel}")
    
    # Broadcast to all clients
    await broadcast({
        'type': 'spell.active_update',
        'spell_id': spell_id,
        'revision_id': revision_id,
        'channel': channel,
        'manifest': manifest
    })
    
    await broadcast({
        'type': 'spell.revision_ready',
        'spell_id': spell_id,
        'revision_id': revision_id,
        'manifest': manifest
    })


async def handle_list_spells(websocket, data: Dict[str, Any]):
    """List all spells."""
    spells = get_all_spells()
    await send_to_client(websocket, {'type': 'spell.list_result', 'spells': spells})


async def handle_get_revisions(websocket, data: Dict[str, Any]):
    """Get all revisions for a spell."""
    spell_id = data.get('spell_id')
    if not spell_id:
        await send_to_client(websocket, {'type': 'error', 'message': 'spell_id required'})
        return
    
    revisions = get_spell_revisions(spell_id)
    await send_to_client(websocket, {
        'type': 'spell.revisions_result',
        'spell_id': spell_id,
        'revisions': revisions
    })


# ============================================================================
# Content Distribution Handlers
# ============================================================================

async def handle_get_manifest(websocket, data: Dict[str, Any]):
    """Get manifest for a specific revision."""
    spell_id = data.get('spell_id')
    revision_id = data.get('revision_id')
    
    if not spell_id or not revision_id:
        await send_to_client(websocket, {'type': 'error', 'message': 'spell_id and revision_id required'})
        return
    
    manifest = read_manifest(spell_id, revision_id)
    
    if not manifest:
        await send_to_client(websocket, {'type': 'error', 'message': 'Manifest not found'})
        return
    
    await send_to_client(websocket, {
        'type': 'content.manifest',
        'spell_id': spell_id,
        'revision_id': revision_id,
        'manifest': manifest
    })


async def handle_get_file(websocket, data: Dict[str, Any]):
    """Get a specific file from a revision."""
    spell_id = data.get('spell_id')
    revision_id = data.get('revision_id')
    path = data.get('path')
    
    if not all([spell_id, revision_id, path]):
        await send_to_client(websocket, {'type': 'error', 'message': 'spell_id, revision_id, and path required'})
        return
    
    content = read_revision_file(spell_id, revision_id, path)
    
    if content is None:
        await send_to_client(websocket, {'type': 'error', 'message': f'File not found: {path}'})
        return
    
    await send_to_client(websocket, {
        'type': 'content.file',
        'spell_id': spell_id,
        'revision_id': revision_id,
        'path': path,
        'content': base64.b64encode(content).decode('ascii'),
        'size': len(content)
    })


async def handle_list_files(websocket, data: Dict[str, Any]):
    """List all files in a revision."""
    spell_id = data.get('spell_id')
    revision_id = data.get('revision_id')
    
    if not spell_id or not revision_id:
        await send_to_client(websocket, {'type': 'error', 'message': 'spell_id and revision_id required'})
        return
    
    files = list_revision_files(spell_id, revision_id)
    
    await send_to_client(websocket, {
        'type': 'content.files_list',
        'spell_id': spell_id,
        'revision_id': revision_id,
        'files': files
    })


# ============================================================================
# Spell Casting Handler
# ============================================================================

async def handle_cast_request(websocket, data: Dict[str, Any]):
    """Handle a spell cast request."""
    import random
    from datetime import timezone
    
    world_id = client_worlds.get(websocket)
    
    if not world_id:
        await send_to_client(websocket, {
            'type': 'spell.cast_rejected',
            'spell_id': data.get('spell_id', ''),
            'error': 'Must join a world first'
        })
        return
    
    spell_id = data.get('spell_id')
    revision_id = data.get('revision_id')
    cast_params = data.get('cast_params', {})
    
    if not spell_id:
        await send_to_client(websocket, {'type': 'error', 'message': 'spell_id required'})
        return
    
    if not spell_exists(spell_id):
        await send_to_client(websocket, {
            'type': 'spell.cast_rejected',
            'spell_id': spell_id,
            'error': 'Spell not found'
        })
        return
    
    # Get active revision if not specified
    if not revision_id:
        spell = get_spell(spell_id)
        revision_id = spell.get('active_beta_rev') or spell.get('active_stable_rev')
    
    if not revision_id:
        await send_to_client(websocket, {
            'type': 'spell.cast_rejected',
            'spell_id': spell_id,
            'error': 'No active revision'
        })
        return
    
    # Generate deterministic seed
    cast_seed = random.randint(0, 2**31 - 1)
    caster_id = str(id(websocket))
    
    logger.info(f"Cast: {spell_id} rev {revision_id} by {caster_id} in world {world_id}")
    
    # Broadcast to all clients in the world
    await broadcast_to_world(world_id, {
        'type': 'spell.cast_event',
        'spell_id': spell_id,
        'revision_id': revision_id,
        'caster_id': caster_id,
        'world_id': world_id,
        'cast_params': cast_params,
        'seed': cast_seed,
        'timestamp': datetime.now(timezone.utc).isoformat()
    })


# ============================================================================
# Legacy World Ops Handlers
# ============================================================================

async def handle_legacy_spell(websocket, data: Dict[str, Any]):
    """Handle legacy spell requests (create_land, dig)."""
    world_id = client_worlds.get(websocket)
    
    if not world_id:
        await send_to_client(websocket, {'type': 'spell_rejected', 'error': 'Must join a world first'})
        return
    
    spell = data.get('spell', {})
    spell_type = spell.get('type', '')
    
    if spell_type not in ['create_land', 'dig']:
        await send_to_client(websocket, {'type': 'spell_rejected', 'error': f'Unknown type: {spell_type}'})
        return
    
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
    
    for op in ops:
        # Store in database
        add_world_op(world_id, op['op'], {
            'center': op.get('center'),
            'radius': op.get('radius'),
            'material_id': op.get('material_id')
        })
        logger.info(f"Broadcasting op to world {world_id}: {op['op']} at {op.get('center', 'unknown')}")
        await broadcast_to_world(world_id, {'type': 'apply_op', 'op': op})


async def handle_ping(websocket, data: Dict[str, Any]):
    """Handle ping request."""
    world_id = client_worlds.get(websocket)
    world_ops_count = 0
    if world_id:
        world_ops_count = len(get_world_ops(world_id))
    
    await send_to_client(websocket, {
        'type': 'pong',
        'clients': len(connected_clients),
        'world_id': world_id,
        'ops': world_ops_count
    })


async def handle_clear_world(websocket, data: Dict[str, Any]):
    """Handle world clear request."""
    world_id = client_worlds.get(websocket)
    
    if not world_id:
        await send_to_client(websocket, {'type': 'error', 'message': 'Must join a world first'})
        return
    
    cleared_count = clear_world_ops(world_id)
    logger.info(f"World {world_id} cleared ({cleared_count} ops)")
    await broadcast_to_world(world_id, {'type': 'world_cleared', 'world_id': world_id})


# ============================================================================
# Connection Handler
# ============================================================================

async def handle_client(websocket: websockets.WebSocketServerProtocol):
    """Handle a client connection."""
    from datetime import timezone
    
    connected_clients.add(websocket)
    client_addr = websocket.remote_address
    logger.info(f"Client connected from {client_addr}. Total: {len(connected_clients)}")
    
    try:
        # Send connection acknowledgment
        # Client should then request world list and join a world
        await send_to_client(websocket, {
            'type': 'connected',
            'client_id': str(id(websocket)),
            'server_time': datetime.now(timezone.utc).isoformat()
        })
        
        # Handle messages
        async for message in websocket:
            await handle_message(websocket, message)
    
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        # Leave current world if in one
        world_id = client_worlds.pop(websocket, None)
        if world_id:
            update_world_player_count(world_id, -1)
            logger.info(f"Client left world {world_id}")
        
        connected_clients.discard(websocket)
        logger.info(f"Client disconnected from {client_addr}. Total: {len(connected_clients)}")


# ============================================================================
# Main Entry Point
# ============================================================================

async def main():
    """Start the WebSocket server."""
    global main_loop
    main_loop = asyncio.get_event_loop()
    
    print("=" * 60)
    print("UGC World Backend Server with Spell System")
    print("=" * 60)
    
    # Initialize database
    init_database()
    
    # Start job worker with progress callback
    start_worker(on_job_progress)
    
    print(f"WebSocket server starting on ws://{HOST}:{PORT}")
    print(f"Health check available at http://{HOST}:{PORT}/health")
    print("=" * 60)
    
    async with websockets.serve(
        handle_client,
        HOST,
        PORT,
        process_request=process_request,
        # Increase timeouts for production
        ping_interval=30,
        ping_timeout=30,
    ):
        logger.info(f"Server listening on ws://{HOST}:{PORT}")
        await asyncio.Future()  # Run forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nServer shutting down...")
