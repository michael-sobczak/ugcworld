"""
UGC World Control Plane Server

Handles:
- Player authentication and session management
- Matchmaking and game server assignment
- World persistence
- Spell package system (build, publish, distribute)
- Game server lifecycle management
- WebSocket for real-time updates (spell builds, etc.)

Run with: python app.py
"""

import os
import json
import uuid
import time
import subprocess
import logging
import secrets
import base64
from datetime import datetime, timedelta, timezone
from typing import Dict, Any, Optional, Set
from pathlib import Path

from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
from flask_socketio import SocketIO, emit, join_room, leave_room

from database import (
    init_database,
    # World
    create_world, get_world, get_all_worlds, world_exists,
    update_world_player_count, delete_world,
    save_world_state, load_world_state,
    # Spell
    create_spell, get_spell, get_all_spells, spell_exists,
    update_spell_active_revision, get_spell_revisions,
    # Revision
    get_revision,
    # Job
    create_job, get_job, update_job,
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
CORS(app)

# Socket.IO for real-time updates
socketio = SocketIO(
    app,
    cors_allowed_origins="*",
    async_mode='threading',
    ping_timeout=60,
    ping_interval=25
)

# =============================================================================
# In-Memory State
# =============================================================================

# Active sessions: session_token -> SessionData
active_sessions: Dict[str, Dict[str, Any]] = {}

# Running game servers: world_id -> ServerInfo
running_servers: Dict[str, Dict[str, Any]] = {}

# Connected WebSocket clients
connected_clients: Set[str] = set()
client_worlds: Dict[str, str] = {}  # client_id -> world_id

SESSION_EXPIRY_SECONDS = 4 * 60 * 60


# =============================================================================
# Session Management
# =============================================================================

def create_session(username: str = "") -> Dict[str, Any]:
    """Create a new session."""
    session_token = secrets.token_urlsafe(32)
    client_id = f"client_{uuid.uuid4().hex[:12]}"
    
    session = {
        "session_token": session_token,
        "client_id": client_id,
        "username": username or f"Player_{client_id[-6:]}",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "expires_at": (datetime.now(timezone.utc) + timedelta(seconds=SESSION_EXPIRY_SECONDS)).isoformat(),
    }
    
    active_sessions[session_token] = session
    logger.info(f"Created session for {session['username']}")
    return session


def validate_session(session_token: str) -> Optional[Dict[str, Any]]:
    """Validate a session token."""
    session = active_sessions.get(session_token)
    if not session:
        return None
    
    expires_at = datetime.fromisoformat(session["expires_at"])
    if datetime.now(timezone.utc) > expires_at:
        active_sessions.pop(session_token, None)
        return None
    
    return session


# =============================================================================
# Game Server Management
# =============================================================================

def get_or_start_game_server(world_id: str) -> Dict[str, Any]:
    """Get running game server or start a new one."""
    if world_id in running_servers:
        server_info = running_servers[world_id]
        if _is_server_alive(server_info):
            return server_info
        running_servers.pop(world_id, None)
    
    server_info = _start_game_server(world_id)
    if server_info:
        running_servers[world_id] = server_info
    
    return server_info


def _is_server_alive(server_info: Dict[str, Any]) -> bool:
    """Check if game server process is running."""
    process = server_info.get("process")
    return process and process.poll() is None


def _start_game_server(world_id: str) -> Optional[Dict[str, Any]]:
    """Start a new headless Godot game server."""
    base_port = _find_available_port()
    if not base_port:
        logger.error("No available ports")
        return None
    
    godot_path = os.environ.get("GODOT_PATH", "godot")
    server_project = os.environ.get("GAME_SERVER_PATH", "../server_godot")
    control_plane_port = os.environ.get("PORT", "5000")
    
    # Resolve relative path
    if not os.path.isabs(server_project):
        server_project = os.path.join(os.path.dirname(__file__), server_project)
    server_project = os.path.abspath(server_project)
    
    cmd = [
        godot_path,
        "--headless",
        "--path", server_project,
        "--",
        "--port", str(base_port),
        "--world", world_id,
        "--control-plane", f"http://127.0.0.1:{control_plane_port}",
    ]
    
    logger.info(f"Starting game server: {' '.join(cmd)}")
    
    try:
        # Capture stdout to read the actual port
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,  # Line buffered
        )
        
        # Read output to find the actual port (Godot will try multiple ports if needed)
        import socket
        import select
        import threading
        import re
        
        actual_port = None
        server_ready = threading.Event()
        output_lines = []
        
        def read_output():
            nonlocal actual_port
            for line in process.stdout:
                line = line.strip()
                output_lines.append(line)
                # Print to our console too
                print(f"[GameServer] {line}")
                
                # Look for the machine-readable port output
                if line.startswith("GAMESERVER_PORT="):
                    try:
                        actual_port = int(line.split("=")[1])
                        logger.info(f"Game server reported port: {actual_port}")
                    except ValueError:
                        pass
                
                # Also detect successful startup
                if "TCP server listening on port" in line:
                    server_ready.set()
        
        # Start reading output in a thread
        reader_thread = threading.Thread(target=read_output, daemon=True)
        reader_thread.start()
        
        # Wait for server to report ready
        max_wait = 10.0
        if not server_ready.wait(timeout=max_wait):
            # Check if process is still running
            if process.poll() is not None:
                logger.error(f"Game server process exited with code: {process.returncode}")
                return None
            logger.warning(f"Game server did not report ready within {max_wait}s, checking port...")
        
        # If we didn't get the port from output, fall back to base_port
        if actual_port is None:
            actual_port = base_port
            logger.warning(f"Using base port {actual_port} (couldn't parse actual port from output)")
        
        # Verify the port is actually listening
        poll_interval = 0.2
        waited = 0.0
        max_port_wait = 5.0
        
        while waited < max_port_wait:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(0.2)
            result = sock.connect_ex(('127.0.0.1', actual_port))
            sock.close()
            
            if result == 0:
                logger.info(f"Verified game server listening on port {actual_port}")
                break
            
            if process.poll() is not None:
                logger.error(f"Game server process died (exit code: {process.returncode})")
                return None
            
            time.sleep(poll_interval)
            waited += poll_interval
        else:
            logger.error(f"Game server not responding on port {actual_port}")
            return None
        
        server_info = {
            "world_id": world_id,
            "host": "127.0.0.1",
            "port": actual_port,
            "address": f"ws://127.0.0.1:{actual_port}",
            "process": process,
            "started_at": datetime.now(timezone.utc).isoformat(),
        }
        
        logger.info(f"Game server started: {server_info['address']}")
        return server_info
        
    except FileNotFoundError:
        logger.error(f"Godot not found at: {godot_path}")
        return None
    except Exception as e:
        logger.error(f"Failed to start game server: {e}")
        import traceback
        traceback.print_exc()
        return None


def _find_available_port(start: int = 7777, end: int = 7877) -> Optional[int]:
    """Find an available port based on running servers.
    
    Note: We don't try to bind here to avoid race conditions.
    The Godot server will try multiple ports if needed and report the actual port.
    """
    # Clean up dead servers from running_servers first
    dead_worlds = []
    for world_id, server_info in running_servers.items():
        if not _is_server_alive(server_info):
            dead_worlds.append(world_id)
    for world_id in dead_worlds:
        logger.info(f"Cleaning up dead server for world {world_id}")
        running_servers.pop(world_id, None)
    
    # Get ports used by active servers
    used_ports = {info["port"] for info in running_servers.values() if _is_server_alive(info)}
    
    # Find first port not in use by our servers
    for port in range(start, end):
        if port not in used_ports:
            logger.info(f"Suggesting port: {port} (active servers using: {used_ports or 'none'})")
            return port
    
    logger.error(f"No available ports in range {start}-{end}")
    return None


def stop_game_server(world_id: str) -> bool:
    """Stop a game server."""
    server_info = running_servers.pop(world_id, None)
    if not server_info:
        return False
    
    process = server_info.get("process")
    if process:
        process.terminate()
        try:
            process.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            process.kill()
    
    logger.info(f"Stopped game server for {world_id}")
    return True


# =============================================================================
# Job Progress Callback
# =============================================================================

def on_job_progress(job_id: str, stage: str, pct: int, message: str, extras: Dict):
    """Callback from job worker - emit via WebSocket."""
    payload = {
        "type": "job.progress",
        "job_id": job_id,
        "stage": stage,
        "pct": pct,
        "message": message,
    }
    
    if extras.get("revision_id"):
        payload["revision_id"] = extras["revision_id"]
    if extras.get("manifest"):
        payload["manifest"] = extras["manifest"]
    
    socketio.emit("message", payload)
    logger.info(f"[Job {job_id}] {stage} {pct}% - {message}")


# =============================================================================
# HTTP API Endpoints
# =============================================================================

@app.route("/health", methods=["GET"])
@app.route("/healthz", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "sessions": len(active_sessions),
        "servers": len(running_servers),
    })


# Auth
@app.route("/login", methods=["POST"])
def login():
    data = request.get_json() or {}
    session = create_session(data.get("username", ""))
    return jsonify({
        "session_token": session["session_token"],
        "client_id": session["client_id"],
        "username": session["username"],
    })


@app.route("/session", methods=["GET"])
def get_session_info():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return jsonify({"error": "Missing authorization"}), 401
    
    session = validate_session(auth[7:])
    if not session:
        return jsonify({"error": "Invalid session"}), 401
    
    return jsonify({
        "client_id": session["client_id"],
        "username": session["username"],
    })


# Matchmaking
@app.route("/join", methods=["POST"])
def join():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return jsonify({"error": "Missing authorization"}), 401
    
    session = validate_session(auth[7:])
    if not session:
        return jsonify({"error": "Invalid session"}), 401
    
    data = request.get_json() or {}
    world_id = data.get("world_id")
    
    if not world_id:
        world = create_world(data.get("name", "New World"), data.get("description", ""))
        world_id = world["world_id"]
    elif not world_exists(world_id):
        return jsonify({"error": f"World {world_id} not found"}), 404
    
    server_info = get_or_start_game_server(world_id)
    if not server_info:
        return jsonify({"error": "Failed to start game server"}), 503
    
    return jsonify({
        "server_address": server_info["address"],
        "session_token": session["session_token"],
        "client_id": session["client_id"],
        "world_id": world_id,
    })


# Worlds
@app.route("/worlds", methods=["GET"])
def list_worlds():
    worlds = get_all_worlds()
    for w in worlds:
        w["online"] = w["world_id"] in running_servers
    return jsonify({"worlds": worlds})


@app.route("/worlds", methods=["POST"])
def create_world_endpoint():
    data = request.get_json() or {}
    world = create_world(data.get("name", ""), data.get("description", ""))
    return jsonify({"world": world})


@app.route("/world/<world_id>", methods=["GET"])
def get_world_endpoint(world_id: str):
    state = load_world_state(world_id)
    if not state:
        world = get_world(world_id)
        if not world:
            return jsonify({"error": "World not found"}), 404
        return jsonify({"world_id": world_id, "chunks": [], "entities": []})
    return jsonify(state)


@app.route("/world/<world_id>", methods=["POST", "PUT"])
def save_world_endpoint(world_id: str):
    data = request.get_json()
    if not data:
        return jsonify({"error": "Missing data"}), 400
    
    save_world_state(
        world_id,
        data.get("chunks", []),
        data.get("entities", []),
        data.get("server_tick", 0)
    )
    return jsonify({"status": "saved"})


@app.route("/world/<world_id>", methods=["DELETE"])
def delete_world_endpoint(world_id: str):
    stop_game_server(world_id)
    delete_world(world_id)
    return jsonify({"status": "deleted"})


# Spells
@app.route("/api/spells", methods=["GET"])
def api_list_spells():
    return jsonify({"spells": get_all_spells()})


@app.route("/api/spells/<spell_id>/revisions", methods=["GET"])
def api_list_spell_revisions(spell_id: str):
    return jsonify({"spell_id": spell_id, "revisions": get_spell_revisions(spell_id)})


@app.route("/api/spells/<spell_id>/revisions/<revision_id>/manifest", methods=["GET"])
def api_get_spell_manifest(spell_id: str, revision_id: str):
    manifest = read_manifest(spell_id, revision_id)
    if not manifest:
        return jsonify({"error": "Manifest not found"}), 404
    return jsonify({"spell_id": spell_id, "revision_id": revision_id, "manifest": manifest})


@app.route("/api/spells/<spell_id>/revisions/<revision_id>/files/<path:file_path>", methods=["GET"])
def api_get_spell_file(spell_id: str, revision_id: str, file_path: str):
    revision_dir = get_revision_dir(spell_id, revision_id)
    full_path = os.path.join(revision_dir, file_path)
    
    if not os.path.exists(full_path):
        return jsonify({"error": "File not found"}), 404
    
    return send_file(full_path)


@app.route("/api/spells/<spell_id>/build", methods=["POST"])
def api_start_spell_build(spell_id: str):
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return jsonify({"error": "Missing authorization"}), 401
    session = validate_session(auth[7:])
    if not session:
        return jsonify({"error": "Invalid session"}), 401

    data = request.get_json() or {}
    if not spell_id:
        return jsonify({"error": "spell_id required"}), 400

    if not spell_exists(spell_id):
        create_spell(spell_id)

    job_id = f"job_{uuid.uuid4().hex[:12]}"
    create_job(job_id, spell_id)

    build_options = {
        "prompt": data.get("prompt", ""),
        "code": data.get("code"),
        "parent_revision_id": data.get("options", {}).get("parent_revision_id"),
        "metadata": data.get("options", {}).get("metadata", {}),
    }

    worker = get_worker()
    worker.enqueue_job(job_id, build_options)

    return jsonify({"job_id": job_id, "spell_id": spell_id})


@app.route("/api/spells/<spell_id>/publish", methods=["POST"])
def api_publish_spell(spell_id: str):
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return jsonify({"error": "Missing authorization"}), 401
    session = validate_session(auth[7:])
    if not session:
        return jsonify({"error": "Invalid session"}), 401

    data = request.get_json() or {}
    revision_id = data.get("revision_id")
    channel = data.get("channel", "beta")
    if not revision_id:
        return jsonify({"error": "revision_id required"}), 400
    if not revision_exists(spell_id, revision_id):
        return jsonify({"error": "Revision not found"}), 404

    update_spell_active_revision(spell_id, channel, revision_id)
    manifest = read_manifest(spell_id, revision_id)
    return jsonify({
        "spell_id": spell_id,
        "revision_id": revision_id,
        "channel": channel,
        "manifest": manifest or {}
    })


@app.route("/api/jobs/<job_id>", methods=["GET"])
def api_get_job(job_id: str):
    job = get_job(job_id)
    if not job:
        return jsonify({"error": "Job not found"}), 404
    return jsonify(job)


# Admin
@app.route("/admin/servers", methods=["GET"])
def admin_list_servers():
    servers = [{
        "world_id": info["world_id"],
        "address": info["address"],
        "alive": _is_server_alive(info),
    } for info in running_servers.values()]
    return jsonify({"servers": servers})


@app.route("/admin/servers/<world_id>", methods=["DELETE"])
def admin_stop_server(world_id: str):
    success = stop_game_server(world_id)
    return jsonify({"status": "stopped" if success else "not_found"})


# =============================================================================
# WebSocket Events
# =============================================================================

@socketio.on('connect')
def handle_connect():
    client_id = request.sid
    connected_clients.add(client_id)
    logger.info(f"WebSocket connected: {client_id}")
    emit('message', {'type': 'connected', 'client_id': client_id})


@socketio.on('disconnect')
def handle_disconnect():
    client_id = request.sid
    world_id = client_worlds.pop(client_id, None)
    if world_id:
        leave_room(world_id)
        update_world_player_count(world_id, -1)
    connected_clients.discard(client_id)
    logger.info(f"WebSocket disconnected: {client_id}")


@socketio.on('message')
def handle_message(data: Dict[str, Any]):
    """Handle incoming WebSocket messages."""
    if not isinstance(data, dict):
        return
    
    msg_type = data.get("type", "")
    client_id = request.sid
    
    if msg_type == "world.join":
        _handle_world_join(client_id, data)
    elif msg_type == "world.leave":
        _handle_world_leave(client_id, data)
    elif msg_type == "world.list":
        _handle_world_list(client_id)
    elif msg_type == "spell.create_draft":
        _handle_spell_create_draft(client_id, data)
    elif msg_type == "spell.start_build":
        _handle_spell_start_build(client_id, data)
    elif msg_type == "spell.publish":
        _handle_spell_publish(client_id, data)
    elif msg_type == "spell.list":
        _handle_spell_list(client_id)
    elif msg_type == "spell.get_revisions":
        _handle_spell_get_revisions(client_id, data)
    elif msg_type == "content.get_manifest":
        _handle_get_manifest(client_id, data)
    elif msg_type == "content.get_file":
        _handle_get_file(client_id, data)
    elif msg_type == "ping":
        emit('message', {'type': 'pong', 'clients': len(connected_clients)})


def _handle_world_join(client_id: str, data: Dict):
    world_id = data.get("world_id")
    if not world_id or not world_exists(world_id):
        emit('message', {'type': 'error', 'message': 'World not found'})
        return
    
    old_world = client_worlds.get(client_id)
    if old_world:
        leave_room(old_world)
        update_world_player_count(old_world, -1)
    
    join_room(world_id)
    client_worlds[client_id] = world_id
    update_world_player_count(world_id, 1)
    
    world = get_world(world_id)
    emit('message', {'type': 'world.joined', 'world_id': world_id, 'world': world})


def _handle_world_leave(client_id: str, data: Dict):
    world_id = client_worlds.pop(client_id, None)
    if world_id:
        leave_room(world_id)
        update_world_player_count(world_id, -1)
    emit('message', {'type': 'world.left', 'world_id': world_id})


def _handle_world_list(client_id: str):
    worlds = get_all_worlds()
    for w in worlds:
        w["online"] = w["world_id"] in running_servers
    emit('message', {'type': 'world.list_result', 'worlds': worlds})


def _handle_spell_create_draft(client_id: str, data: Dict):
    spell_id = data.get("spell_id") or f"spell_{uuid.uuid4().hex[:8]}"
    
    created = False
    if not spell_exists(spell_id):
        create_spell(spell_id)
        created = True
    
    spell = get_spell(spell_id)
    emit('message', {'type': 'spell.draft_created', 'spell_id': spell_id, 'created': created, 'spell': spell})


def _handle_spell_start_build(client_id: str, data: Dict):
    spell_id = data.get("spell_id")
    if not spell_id:
        emit('message', {'type': 'error', 'message': 'spell_id required'})
        return
    
    if not spell_exists(spell_id):
        create_spell(spell_id)
    
    job_id = f"job_{uuid.uuid4().hex[:12]}"
    create_job(job_id, spell_id)
    
    build_options = {
        'prompt': data.get('prompt', ''),
        'code': data.get('code'),
        'parent_revision_id': data.get('options', {}).get('parent_revision_id'),
        'metadata': data.get('options', {}).get('metadata', {})
    }
    
    worker = get_worker()
    worker.enqueue_job(job_id, build_options)
    
    emit('message', {'type': 'spell.build_started', 'job_id': job_id, 'spell_id': spell_id})


def _handle_spell_publish(client_id: str, data: Dict):
    spell_id = data.get("spell_id")
    revision_id = data.get("revision_id")
    channel = data.get("channel", "beta")
    
    if not spell_id or not revision_id:
        emit('message', {'type': 'error', 'message': 'spell_id and revision_id required'})
        return
    
    if not revision_exists(spell_id, revision_id):
        emit('message', {'type': 'error', 'message': 'Revision not found'})
        return
    
    update_spell_active_revision(spell_id, channel, revision_id)
    manifest = read_manifest(spell_id, revision_id)
    
    # Broadcast to all clients
    socketio.emit('message', {
        'type': 'spell.active_update',
        'spell_id': spell_id,
        'revision_id': revision_id,
        'channel': channel,
        'manifest': manifest,
    })


def _handle_spell_list(client_id: str):
    spells = get_all_spells()
    emit('message', {'type': 'spell.list_result', 'spells': spells})


def _handle_spell_get_revisions(client_id: str, data: Dict):
    spell_id = data.get("spell_id")
    if not spell_id:
        return
    
    revisions = get_spell_revisions(spell_id)
    emit('message', {'type': 'spell.revisions_result', 'spell_id': spell_id, 'revisions': revisions})


def _handle_get_manifest(client_id: str, data: Dict):
    spell_id = data.get("spell_id")
    revision_id = data.get("revision_id")
    
    if not spell_id or not revision_id:
        return
    
    manifest = read_manifest(spell_id, revision_id)
    if manifest:
        emit('message', {'type': 'content.manifest', 'spell_id': spell_id, 'revision_id': revision_id, 'manifest': manifest})


def _handle_get_file(client_id: str, data: Dict):
    spell_id = data.get("spell_id")
    revision_id = data.get("revision_id")
    path = data.get("path")
    
    if not all([spell_id, revision_id, path]):
        return
    
    content = read_revision_file(spell_id, revision_id, path)
    if content is not None:
        emit('message', {
            'type': 'content.file',
            'spell_id': spell_id,
            'revision_id': revision_id,
            'path': path,
            'content': base64.b64encode(content).decode('ascii'),
            'size': len(content),
        })


# =============================================================================
# Main
# =============================================================================

def main():
    print("=" * 60)
    print("UGC World Control Plane")
    print("=" * 60)
    
    init_database()
    start_worker(on_job_progress)
    
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", 5000))
    
    print(f"Server: http://{host}:{port}")
    print(f"WebSocket: ws://{host}:{port}")
    print("=" * 60)
    
    socketio.run(app, host=host, port=port, debug=False, allow_unsafe_werkzeug=True)


if __name__ == "__main__":
    main()
