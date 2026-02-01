# UGC World Backend Server

A Python WebSocket server that handles the game's server-side logic:
- Client connections
- Spell validation and compilation to ops
- Broadcasting ops to all connected clients
- Late-join synchronization via op_log replay

## Requirements

- Python 3.10+
- websockets library

## Installation

```bash
cd ugc_backend
pip install -r requirements.txt
```

## Running the Server

```bash
python app.py
```

The server will start on `ws://0.0.0.0:5000` by default.

## Configuration

Edit the constants in `app.py` to change:
- `HOST`: Server bind address (default: `"0.0.0.0"`)
- `PORT`: Server port (default: `5000`)

## Protocol

The server uses JSON messages over WebSocket.

### Client → Server Messages

#### request_spell
Request to cast a spell. Server validates and broadcasts resulting ops.

```json
{
    "type": "request_spell",
    "spell": {
        "type": "create_land",
        "center": {"x": 0, "y": 10, "z": 0},
        "radius": 8.0,
        "material_id": 1
    }
}
```

Spell types:
- `create_land`: Creates terrain (add_sphere op)
- `dig`: Removes terrain (subtract_sphere op)

#### ping
Connection health check.

```json
{"type": "ping"}
```

#### clear_world
Admin command to clear all world state.

```json
{"type": "clear_world"}
```

### Server → Client Messages

#### sync_ops
Sent on connection with all existing ops for late-join sync.

```json
{
    "type": "sync_ops",
    "ops": [
        {"op": "add_sphere", "center": {"x": 0, "y": 0, "z": 0}, "radius": 8.0, "material_id": 1}
    ]
}
```

#### sync_complete
Sent on connection if the world is empty.

```json
{
    "type": "sync_complete",
    "message": "World is empty"
}
```

#### apply_op
Broadcast when a new operation is applied.

```json
{
    "type": "apply_op",
    "op": {
        "op": "add_sphere",
        "center": {"x": 0, "y": 10, "z": 0},
        "radius": 8.0,
        "material_id": 1
    }
}
```

#### spell_rejected
Sent when a spell request is invalid.

```json
{
    "type": "spell_rejected",
    "error": "Missing spell type"
}
```

#### world_cleared
Broadcast when the world is cleared.

```json
{"type": "world_cleared"}
```

#### pong
Response to ping.

```json
{
    "type": "pong",
    "clients": 2,
    "ops": 15
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Python Backend (app.py)                      │
├─────────────────────────────────────────────────────────────────┤
│  WebSocket Server (ws://0.0.0.0:5000)                           │
│    ├── handle_client() - connection lifecycle                   │
│    ├── handle_message() - route incoming messages               │
│    ├── compile_spell_to_ops() - spell → ops conversion          │
│    ├── validate_spell() - security/validation                   │
│    └── broadcast() - send to all clients                        │
│                                                                  │
│  State:                                                          │
│    ├── op_log[] - canonical operation history                   │
│    └── connected_clients{} - active connections                 │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ WebSocket
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Godot Client                                 │
├─────────────────────────────────────────────────────────────────┤
│  Net.gd - WebSocket connection                                   │
│  World.gd - op handling, spell requests                          │
│  VoxelBackend.gd - terrain visualization                         │
│  ClientController.gd - player input                              │
└─────────────────────────────────────────────────────────────────┘
```

## Adding Validation

Extend `validate_spell()` in `app.py`:

```python
def validate_spell(spell: dict) -> tuple[bool, str]:
    # Check mana
    # Check cooldowns
    # Check permissions
    # Anti-cheat validation
    return True, ""
```

## Persistence

Currently, `op_log` is in-memory and lost on restart. To add persistence:

1. Save `op_log` to a database or file
2. Load on server start
3. Consider op compaction for large worlds
