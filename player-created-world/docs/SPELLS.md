# Spell Package System

This document describes the spell package system that allows players to create, distribute, and cast custom spells with hot-loading support.

## Overview

The spell system enables:
- **Versioned spell packages**: Each spell has immutable revisions with code, assets, and metadata
- **Build pipeline**: Server-side job system for creating spell revisions
- **Hot-loading**: Clients can download and execute new spells without restart
- **Multiplayer sync**: All clients execute spells deterministically from server-broadcast events

## Architecture

### Core Concepts

| Concept | Description |
|---------|-------------|
| `spell_id` | Stable identifier (e.g., `fireball`, `demo_spark`) |
| `revision_id` | Immutable build output (e.g., `rev_000001_a3b4c5d6`) |
| `channel` | Distribution channel: `draft`, `beta`, `stable` |
| `active_revision` | Currently selected revision per channel |

### Components

**Server (Flask + Socket.IO)**:
- `database.py` - SQLite schema for spells, revisions, jobs
- `spell_storage.py` - File system operations for packages
- `job_worker.py` - Background build job processor
- `app_socketio.py` - WebSocket server with spell events

**Client (Godot Autoloads)**:
- `SpellCache` - Local cache management and downloads
- `SpellLoader` - Hot-loading of scripts and assets
- `SpellRegistry` - Maps spell IDs to active revisions
- `SpellNet` - Network communication for spell events
- `SpellCastController` - Manages cast flow and execution

**Spell Interface**:
- `SpellModule` - Base class for spell implementations
- `SpellContext` - Context passed to spell methods
- `WorldAPIAdapter` - Safe world interaction API

## Spell Package Format

Each revision is stored at:
```
data/spells/<spell_id>/revisions/<revision_id>/
├── manifest.json
├── code/
│   └── spell.gd
├── assets/
│   ├── icon.png
│   └── (textures, sounds, models...)
└── text/
    └── description.md (optional)
```

### manifest.json

```json
{
  "spell_id": "demo_spark",
  "revision_id": "rev_000001_a3b4c5d6",
  "version": 1,
  "created_at": "2026-02-01T12:00:00Z",
  "entrypoint": "code/spell.gd",
  "language": "gdscript",
  "interface_version": "1.0",
  "code": [
    {"path": "code/spell.gd", "hash": "sha256...", "size": 1234}
  ],
  "assets": [
    {"path": "assets/icon.png", "hash": "sha256...", "size": 5678}
  ],
  "metadata": {
    "name": "Demo Spark",
    "description": "Creates a colorful spark effect",
    "tags": ["effect", "visual"],
    "preview_icon": "assets/icon.png"
  }
}
```

## Spell Interface Contract

Spells must extend `SpellModule` and implement:

```gdscript
extends SpellModule

# Required: Called when the spell is cast
func on_cast(ctx: SpellContext) -> void:
    print("Spell cast at: ", ctx.target_position)
    ctx.world.play_vfx("effect", ctx.target_position, {"color": Color.CYAN})

# Optional: Return metadata
func get_manifest() -> Dictionary:
    return {"name": "My Spell", "description": "Does something cool"}

# Optional: Called each frame for ongoing effects
func on_tick(ctx: SpellContext, dt: float) -> void:
    pass

# Optional: Called when spell is cancelled
func on_cancel(ctx: SpellContext) -> void:
    pass

# Optional: Handle custom events
func on_event(ctx: SpellContext, event: Dictionary) -> void:
    pass
```

### SpellContext Properties

| Property | Type | Description |
|----------|------|-------------|
| `caster_id` | String | ID of the casting player |
| `target_position` | Vector3 | World position target |
| `target_entity_id` | String | Entity being targeted (if any) |
| `world` | WorldAPIAdapter | Interface for world interactions |
| `random_seed` | int | Deterministic seed for synced random |
| `rng` | RandomNumberGenerator | Pre-seeded RNG |
| `mana_budget` | float | Available mana for this cast |
| `cast_time` | float | Unix timestamp of cast |
| `tick_index` | int | Current tick count |
| `params` | Dictionary | Custom cast parameters |
| `manifest` | Dictionary | Spell's manifest data |

### WorldAPIAdapter Methods

```gdscript
# Spawn entities
ctx.world.spawn_entity(scene_path, transform, props)
ctx.world.spawn_simple_mesh(mesh, transform, material)

# Visual/audio effects
ctx.world.play_vfx(asset_id, position, params)
ctx.world.play_sound(asset_id, position, params)

# World mutation (placeholder for voxel integration)
ctx.world.set_voxel(position, value)
ctx.world.set_voxel_region(start, end, value)

# Combat (placeholder)
ctx.world.deal_damage(entity_id, amount, damage_type)
ctx.world.query_radius(position, radius, filter)

# Events
ctx.world.emit_event(event_name, event_data)
```

## Network Events

### Server → Client

| Event | Data | Description |
|-------|------|-------------|
| `job.progress` | `{job_id, stage, pct, message, preview?}` | Build progress update |
| `spell.revision_ready` | `{spell_id, revision_id, manifest}` | New revision available |
| `spell.active_update` | `{spell_id, revision_id, channel, manifest}` | Active revision changed |
| `spell.cast_event` | `{spell_id, revision_id, caster_id, cast_params, seed}` | Execute a spell |

### Client → Server

| Event | Data | Description |
|-------|------|-------------|
| `spell.create_draft` | `{spell_id?}` | Create new spell |
| `spell.start_build` | `{spell_id, prompt?, code?, options?}` | Start build job |
| `spell.publish` | `{spell_id, revision_id, channel}` | Publish to channel |
| `spell.cast_request` | `{spell_id, revision_id, cast_params}` | Request spell cast |
| `content.get_manifest` | `{spell_id, revision_id}` | Get manifest |
| `content.get_file` | `{spell_id, revision_id, path}` | Get file content |

## Cast Synchronization Flow

1. **Client A** initiates cast → `spell.cast_request`
2. **Server** validates → broadcasts `spell.cast_event` to ALL clients
3. **All clients** (including A):
   - Ensure revision is cached (download if needed)
   - Load spell module
   - Call `on_cast(ctx)` with synced seed
4. Deterministic RNG ensures identical execution across clients

## Cache Locations

**Client (Godot)**:
```
user://spell_cache/<spell_id>/<revision_id>/
├── manifest.json
├── code/spell.gd
└── assets/...
```

**Server (Flask)**:
```
ugc_backend/data/spells/<spell_id>/revisions/<revision_id>/...
ugc_backend/data/spells.db  (SQLite database)
```

## Adding a Spell Manually (Testing)

1. Create spell directory:
```bash
mkdir -p ugc_backend/data/spells/my_spell/revisions/rev_000001
```

2. Create `code/spell.gd`:
```gdscript
extends SpellModule

func on_cast(ctx: SpellContext) -> void:
    print("My custom spell!")
    ctx.world.play_vfx("spark", ctx.target_position, {"color": Color.RED})
```

3. Create `manifest.json`:
```json
{
  "spell_id": "my_spell",
  "revision_id": "rev_000001",
  "version": 1,
  "created_at": "2026-02-01T00:00:00Z",
  "entrypoint": "code/spell.gd",
  "language": "gdscript",
  "interface_version": "1.0",
  "code": [{"path": "code/spell.gd", "hash": "", "size": 0}],
  "assets": [],
  "metadata": {"name": "My Spell", "description": "Test"}
}
```

4. Register in database (or use API):
```python
from database import create_spell, create_revision, update_spell_active_revision
import json

# Create spell
create_spell("my_spell", "My Spell")

# Register revision
manifest = json.load(open("data/spells/my_spell/revisions/rev_000001/manifest.json"))
create_revision("rev_000001", "my_spell", manifest, "beta", 1)

# Set active
update_spell_active_revision("my_spell", "beta", "rev_000001")
```

## Demo Usage

1. **Start the server**:
```bash
cd ugc_backend
pip install -r requirements.txt
python app_socketio.py
```

2. **Run the Godot client** (open project in Godot, press F5)

3. **Controls**:
   - `C` or `Enter`: Connect to server
   - `5`: Build demo_spark
   - `6`: Build demo_spawn
   - `7`: Publish demo_spark to beta
   - `8`: Publish demo_spawn to beta
   - `3`: Cast demo_spark at cursor
   - `4`: Cast demo_spawn at cursor
   - `WASD`: Move camera
   - `Right-click`: Toggle mouse look

4. **Multi-client test**:
   - Open two Godot instances
   - Both connect to server
   - One client builds + publishes a spell
   - Both clients can immediately cast it

## Future Improvements

- **Security**: Sandbox spell execution, capability-based permissions
- **CDN**: Blob storage for assets with content-addressed deduplication
- **Server authority**: Move spell simulation to server
- **AI generation**: Integrate LLM for generating spell code from prompts
- **Dependencies**: Allow spells to depend on shared libraries
