"""
UGC World Backend Server

A minimal WebSocket server that handles:
- Client connections
- Spell request validation and compilation to ops
- Broadcasting ops to all connected clients
- Late-join sync via op_log replay

Run with: python app.py
"""

import asyncio
import websockets
import json
import logging
from typing import Set

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)
logger = logging.getLogger(__name__)

# Server configuration
HOST = "0.0.0.0"
PORT = 5000

# World state
op_log: list[dict] = []
connected_clients: Set[websockets.WebSocketServerProtocol] = set()


def compile_spell_to_ops(spell: dict) -> list[dict]:
    """Convert a spell dictionary to a list of world operations."""
    spell_type = spell.get("type", "")
    
    if spell_type == "create_land":
        return [{
            "op": "add_sphere",
            "center": spell.get("center", {"x": 0, "y": 0, "z": 0}),
            "radius": float(spell.get("radius", 8.0)),
            "material_id": int(spell.get("material_id", 1))
        }]
    elif spell_type == "dig":
        return [{
            "op": "subtract_sphere",
            "center": spell.get("center", {"x": 0, "y": 0, "z": 0}),
            "radius": float(spell.get("radius", 6.0))
        }]
    
    logger.warning(f"Unknown spell type: {spell_type}")
    return []


def validate_spell(spell: dict) -> tuple[bool, str]:
    """Validate a spell request. Returns (is_valid, error_message)."""
    spell_type = spell.get("type")
    if not spell_type:
        return False, "Missing spell type"
    
    if spell_type not in ["create_land", "dig"]:
        return False, f"Unknown spell type: {spell_type}"
    
    center = spell.get("center")
    if center is None:
        return False, "Missing center"
    
    return True, ""


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


async def send_sync(websocket: websockets.WebSocketServerProtocol):
    """Send op_log to a newly connected client for sync."""
    if op_log:
        logger.info(f"Sending {len(op_log)} ops for sync")
        await websocket.send(json.dumps({
            "type": "sync_ops",
            "ops": op_log
        }))
    else:
        await websocket.send(json.dumps({
            "type": "sync_complete",
            "message": "World is empty"
        }))


async def handle_message(websocket: websockets.WebSocketServerProtocol, message: str):
    """Handle an incoming message from a client."""
    try:
        data = json.loads(message)
    except json.JSONDecodeError:
        logger.warning(f"Invalid JSON received: {message[:100]}")
        return
    
    msg_type = data.get("type", "")
    
    if msg_type == "request_spell":
        spell = data.get("spell", {})
        
        # Validate
        is_valid, error = validate_spell(spell)
        if not is_valid:
            logger.warning(f"Invalid spell: {error}")
            await websocket.send(json.dumps({
                "type": "spell_rejected",
                "error": error
            }))
            return
        
        # Compile to ops
        ops = compile_spell_to_ops(spell)
        
        # Apply and broadcast
        for op in ops:
            op_log.append(op)
            logger.info(f"Broadcasting op: {op['op']} at {op.get('center', 'unknown')}")
            await broadcast({
                "type": "apply_op",
                "op": op
            })
    
    elif msg_type == "ping":
        await websocket.send(json.dumps({
            "type": "pong",
            "clients": len(connected_clients),
            "ops": len(op_log)
        }))
    
    elif msg_type == "clear_world":
        # Admin command to clear world
        op_log.clear()
        logger.info("World cleared")
        await broadcast({"type": "world_cleared"})
    
    else:
        logger.warning(f"Unknown message type: {msg_type}")


async def handle_client(websocket: websockets.WebSocketServerProtocol):
    """Handle a client connection."""
    connected_clients.add(websocket)
    client_addr = websocket.remote_address
    logger.info(f"Client connected from {client_addr}. Total: {len(connected_clients)}")
    
    try:
        # Send sync data
        await send_sync(websocket)
        
        # Handle messages
        async for message in websocket:
            await handle_message(websocket, message)
    
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        connected_clients.discard(websocket)
        logger.info(f"Client disconnected from {client_addr}. Total: {len(connected_clients)}")


async def main():
    """Start the WebSocket server."""
    print("=" * 50)
    print("UGC World Backend Server")
    print("=" * 50)
    print(f"WebSocket server starting on ws://{HOST}:{PORT}")
    print("=" * 50)
    
    async with websockets.serve(handle_client, HOST, PORT):
        logger.info(f"Server listening on ws://{HOST}:{PORT}")
        await asyncio.Future()  # Run forever


if __name__ == "__main__":
    asyncio.run(main())
