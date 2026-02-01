# UGC World Backend

A Python WebSocket server for the Player Created World spell system.

## Features

- **Spell Package System**: Create, build, and distribute versioned spell packages
- **Build Pipeline**: Background job worker for iterative spell creation
- **Hot-Loading Support**: Clients can download and use new spells without restart
- **Multiplayer Sync**: Deterministic spell execution across all clients
- **Legacy Voxel Ops**: Backward-compatible world operations (add/subtract spheres)

## Quick Start

1. **Install dependencies**:
```bash
cd ugc_backend
pip install -r requirements.txt
```

2. **Run the server**:
```bash
python app.py
```

The server will start on `ws://0.0.0.0:5000`.

## Architecture

```
ugc_backend/
├── app.py              # Main WebSocket server
├── database.py         # SQLite database for spell metadata
├── spell_storage.py    # File system storage for spell packages
├── job_worker.py       # Background build job processor
└── data/               # Generated at runtime
    ├── spells.db       # SQLite database
    └── spells/         # Spell revision files
        └── <spell_id>/
            └── revisions/
                └── <revision_id>/
                    ├── manifest.json
                    ├── code/spell.gd
                    └── assets/...
```

## API

### Spell Management

| Message Type | Request Data | Description |
|--------------|--------------|-------------|
| `spell.create_draft` | `{spell_id?}` | Create new spell (generates ID if not provided) |
| `spell.start_build` | `{spell_id, code?, prompt?, options?}` | Start build job |
| `spell.publish` | `{spell_id, revision_id, channel}` | Publish to channel |
| `spell.list` | `{}` | List all spells |
| `spell.get_revisions` | `{spell_id}` | Get spell revisions |
| `spell.cast_request` | `{spell_id, revision_id?, cast_params}` | Request spell cast |

### Content Distribution

| Message Type | Request Data | Description |
|--------------|--------------|-------------|
| `content.get_manifest` | `{spell_id, revision_id}` | Get revision manifest |
| `content.get_file` | `{spell_id, revision_id, path}` | Get file (base64 encoded) |
| `content.list_files` | `{spell_id, revision_id}` | List revision files |

### Server Events

| Event Type | Data | Description |
|------------|------|-------------|
| `connected` | `{client_id, server_time}` | Connection established |
| `job.progress` | `{job_id, stage, pct, message, ...}` | Build progress |
| `spell.build_started` | `{job_id, spell_id}` | Build job started |
| `spell.revision_ready` | `{spell_id, revision_id, manifest}` | New revision available |
| `spell.active_update` | `{spell_id, revision_id, channel}` | Active revision changed |
| `spell.cast_event` | `{spell_id, revision_id, caster_id, ...}` | Execute spell cast |

### Legacy World Ops

| Message Type | Request Data | Description |
|--------------|--------------|-------------|
| `request_spell` | `{spell: {type, center, radius, ...}}` | Legacy voxel operation |
| `ping` | `{}` | Ping server |
| `clear_world` | `{}` | Clear world state |

## Build Job Stages

When a build job runs, it progresses through these stages:

1. **prepare** (0-15%): Setup build environment
2. **assemble_package** (20-55%): Write code and assets
3. **validate** (60-75%): Check spell interface
4. **finalize** (80-95%): Compute hashes, write manifest
5. **done** (100%): Build complete

## Database Schema

```sql
-- Spell identity and active revisions
CREATE TABLE spells (
    spell_id TEXT PRIMARY KEY,
    display_name TEXT,
    active_draft_rev TEXT,
    active_beta_rev TEXT,
    active_stable_rev TEXT,
    created_at TEXT,
    updated_at TEXT
);

-- Immutable revision builds
CREATE TABLE revisions (
    revision_id TEXT PRIMARY KEY,
    spell_id TEXT,
    parent_revision_id TEXT,
    channel TEXT,
    version INTEGER,
    manifest_json TEXT,
    created_at TEXT
);

-- Build jobs
CREATE TABLE jobs (
    job_id TEXT PRIMARY KEY,
    spell_id TEXT,
    draft_id TEXT,
    status TEXT,
    stage TEXT,
    progress_pct INTEGER,
    logs TEXT,
    error_message TEXT,
    result_revision_id TEXT,
    created_at TEXT,
    updated_at TEXT
);
```

## Example: Creating a Spell Manually

```python
from database import init_database, create_spell, create_revision, update_spell_active_revision
from spell_storage import create_revision_directory, write_revision_file_text, write_manifest, create_manifest

# Initialize
init_database()

# Create spell
spell_id = "my_fireball"
create_spell(spell_id, "My Fireball")

# Create revision
revision_id = "rev_000001"
create_revision_directory(spell_id, revision_id)

# Write spell code
code = '''extends SpellModule

func on_cast(ctx: SpellContext) -> void:
    print("Fireball!")
    ctx.world.play_vfx("fire", ctx.target_position, {"color": Color.ORANGE})
'''
code_info = write_revision_file_text(spell_id, revision_id, "code/spell.gd", code)

# Write manifest
manifest = create_manifest(
    spell_id=spell_id,
    revision_id=revision_id,
    version=1,
    code_files=[code_info]
)
write_manifest(spell_id, revision_id, manifest)

# Register and publish
create_revision(revision_id, spell_id, manifest, "beta", 1)
update_spell_active_revision(spell_id, "beta", revision_id)
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Server bind address |
| `PORT` | `5000` | Server port |

## Development

The server uses plain WebSocket for Godot compatibility (no Socket.IO protocol).

For testing with multiple clients:
1. Start the server
2. Open multiple Godot instances
3. Connect all to the same server
4. Build/publish spells from one client
5. All clients receive updates and can cast immediately

## See Also

- [Spell System Documentation](../player-created-world/docs/SPELLS.md)
