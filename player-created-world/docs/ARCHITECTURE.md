# Architecture

Core idea:
- Python backend is authoritative for world state
- World is mutable at runtime via "ops" (operations) emitted by spells
- Clients connect via WebSocket and receive ops to apply locally

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Python Backend (ugc_backend/)                │
├─────────────────────────────────────────────────────────────────┤
│  WebSocket Server (ws://host:5000)                               │
│    ├── Connection handling                                       │
│    ├── Spell validation                                          │
│    ├── Spell → Ops compilation                                   │
│    ├── Op broadcasting to all clients                            │
│    └── Late-join sync (send op_log)                              │
│                                                                   │
│  State:                                                           │
│    └── op_log[] - canonical operation history                    │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ WebSocket (JSON messages)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Godot Client (player-created-world/)         │
├─────────────────────────────────────────────────────────────────┤
│  Net.gd (autoload)                                               │
│    └── WebSocket connection to backend                           │
│                                                                   │
│  World.gd (autoload)                                             │
│    ├── Receives ops from backend                                 │
│    ├── Emits op_applied signal for visualization                 │
│    └── Sends spell requests to backend                           │
│                                                                   │
│  VoxelBackend.gd                                                 │
│    └── Visualizes terrain (CSG spheres for demo)                 │
│                                                                   │
│  ClientController.gd                                             │
│    └── Player input, camera, spell casting                       │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow

```
Player Input (press 1)
       │
       ▼
ClientController._cast_create_land()
       │
       ▼
World.request_spell(spell)
       │
       ▼
Net.send_message({type: "request_spell", spell: {...}})
       │
       │ WebSocket
       ▼
Python Backend: handle_message()
       │
       ├── validate_spell()
       ├── compile_spell_to_ops()
       └── broadcast({type: "apply_op", op: {...}})
       │
       │ WebSocket (to all clients)
       ▼
Net._handle_message() → message_received signal
       │
       ▼
World._on_message_received() → _handle_apply_op()
       │
       ▼
World.op_applied signal
       │
       ▼
VoxelBackend._on_op_applied() → creates CSG sphere
```

## Key Concepts

### Operations (Ops)

Operations are the atomic units of world mutation:

```json
{
    "op": "add_sphere",
    "center": {"x": 0, "y": 10, "z": 0},
    "radius": 8.0,
    "material_id": 1
}
```

Current op types:
- `add_sphere` - Add terrain in a spherical region
- `subtract_sphere` - Remove terrain in a spherical region

### Spells

Spells are player intents that compile to ops:

```json
{
    "type": "create_land",
    "center": {"x": 0, "y": 10, "z": 0},
    "radius": 8.0,
    "material_id": 1
}
```

The backend validates and compiles spells. This separation allows:
- Server-side validation (anti-cheat, permissions, mana)
- Complex spells that generate multiple ops
- Future spell types without client updates

### Late-Join Sync

When a client connects:
1. Backend sends `sync_ops` with entire `op_log`
2. Client replays all ops to reconstruct world state
3. Client emits `sync_complete` signal

## Files Reference

### Python Backend (ugc_backend/)

| File | Purpose |
|------|---------|
| `app.py` | WebSocket server, spell handling |
| `requirements.txt` | Python dependencies |
| `README.md` | Backend documentation |

### Godot Client (player-created-world/)

| File | Purpose |
|------|---------|
| `shared/scripts/net/Net.gd` | WebSocket client (autoload) |
| `shared/scripts/world/World.gd` | Op handling, spell requests (autoload) |
| `shared/scripts/world/VoxelBackend.gd` | Terrain visualization |
| `client/scripts/ClientController.gd` | Player input |
| `client/scenes/Main.tscn` | Main game scene |

## Running

### 1. Start Backend

```bash
cd ugc_backend
pip install -r requirements.txt
python app.py
```

### 2. Run Client

Open Godot, run `client/scenes/Main.tscn`

Or from command line:
```bash
cd player-created-world
godot --main-scene client/scenes/Main.tscn
```

The client auto-connects to `ws://127.0.0.1:5000` by default.

## Extending

### Adding Spell Types

1. **Backend** (`app.py`): Add to `compile_spell_to_ops()`
2. **Backend** (`app.py`): Update `validate_spell()` if needed
3. **Client** (`VoxelBackend.gd`): Handle new op types

### Adding Validation

Edit `validate_spell()` in `app.py`:
```python
def validate_spell(spell: dict) -> tuple[bool, str]:
    # Check player permissions
    # Validate mana cost
    # Anti-cheat checks
    return True, ""
```

### Persistence

Replace in-memory `op_log` with database storage:
1. Save ops on broadcast
2. Load on server start
3. Consider op compaction for optimization
