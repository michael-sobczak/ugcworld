# UGC World

A multiplayer voxel game with player-created spells, powered by local LLM inference.

## Architecture

This project uses a **server-authoritative architecture**:

```
┌─────────────────────┐     ┌─────────────────────┐
│  Control Plane      │     │  Game Server        │
│  (Python Flask)     │────▶│  (Headless Godot)   │
│                     │     │                     │
│  - Authentication   │     │  - Physics          │
│  - Matchmaking      │     │  - Movement         │
│  - Persistence      │     │  - Projectiles      │
│  - Spell Build Jobs │     │  - NPC AI           │
│  - WebSocket Hub    │     │  - Voxel Terrain    │
└─────────────────────┘     │  - Spell Execution  │
         ▲                  └─────────────────────┘
         │                           ▲
         │ HTTP/WS                   │ WS (ENet-like)
         │                           │
┌────────┴───────────────────────────┴──────┐
│              Godot Client                 │
│                                           │
│  - Input collection & prediction          │
│  - Server reconciliation                  │
│  - Rendering & VFX                        │
│  - Local LLM for spell generation         │
└───────────────────────────────────────────┘
```

## Quick Start

### 1. Start the Server

**PowerShell:**
```powershell
.\launch_server.ps1
```

**Bash:**
```bash
source env.sh
cd server_python
pip install -r requirements.txt
python app.py
```

The control plane starts on `http://localhost:5000`. It will spawn headless Godot game servers automatically when clients join worlds.

### 2. Run the Client

1. Open `player-created-world/` in Godot 4.6
2. Run the Main scene (`F5`)
3. Press **C** to open connection dialog
4. Connect to `http://127.0.0.1:5000`
5. Create or join a world

## Project Structure

```
ugcworld/
├── server_python/          # Control Plane (Flask + SocketIO)
│   ├── app.py              # Main server
│   ├── database.py         # SQLite for worlds/spells/jobs
│   ├── spell_storage.py    # Spell file storage
│   └── job_worker.py       # Build job processing
│
├── server_godot/           # Authoritative Game Server (Headless Godot)
│   ├── project.godot
│   ├── server/
│   │   ├── scripts/
│   │   │   ├── GameServer.gd       # Main server loop
│   │   │   ├── ServerPlayer.gd     # Player physics
│   │   │   ├── ChunkManager.gd     # Voxel terrain
│   │   │   ├── ProjectileManager.gd
│   │   │   ├── NPCManager.gd
│   │   │   └── EntityRegistry.gd
│   │   └── scenes/
│   │       └── GameServer.tscn
│   └── shared/protocol/
│       └── Protocol.gd             # Network protocol definitions
│
├── player-created-world/   # Godot Client
│   ├── project.godot
│   ├── client/             # Client-specific code
│   │   ├── scripts/
│   │   │   ├── ClientController.gd
│   │   │   ├── ConnectionDialog.gd
│   │   │   └── WorldSelectionDialog.gd
│   │   └── scenes/
│   │       └── Main.tscn
│   ├── shared/scripts/     # Autoloads
│   │   ├── net/Net.gd      # Network client
│   │   ├── world/          # World state
│   │   └── spells/         # Spell system
│   ├── addons/
│   │   ├── local_llm/      # LLM GDExtension
│   │   └── zylann.voxel/   # Voxel terrain
│   └── models/             # LLM model files
│
├── docs/                   # Documentation
│   ├── network_protocol.md
│   ├── server_architecture.md
│   └── voxel_sync.md
│
├── scripts/                # Build/management scripts
├── env.ps1                 # Environment config (PowerShell)
├── env.sh                  # Environment config (Bash)
├── launch_server.ps1       # Server launcher
└── launch_server.bat       # Server launcher (Windows)
```

## Environment Setup

### Required Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `GODOT_PATH` | Path to Godot 4.6 executable | Required for game server spawn |
| `GAME_SERVER_PATH` | Path to server_godot project | `./server_godot` |
| `PORT` | Control plane port | `5000` |
| `HOST` | Control plane host | `0.0.0.0` |

Edit `env.ps1` (Windows) or `env.sh` (Linux/Mac) with your Godot path.

## Connection Flow

1. **Client Login**: `POST /login` → receive `session_token` and `client_id`
2. **Join World**: `POST /join` → receive `game_server_address`
3. **Connect to Game Server**: WebSocket to game server address
4. **Handshake**: Send session_token, receive assigned entity_id
5. **Gameplay**: Send inputs at 60Hz, receive snapshots at 20Hz

## Network Protocol

All messages are JSON over WebSocket.

### Client → Server

| Type | Description |
|------|-------------|
| `HANDSHAKE` | Authentication with session_token |
| `INPUT_FRAME` | Player inputs (movement, aim, fire, jump) |
| `TERRAFORM_REQUEST` | Voxel edit request |
| `CHUNK_REQUEST` | Request chunk data |
| `SPELL_CAST_REQUEST` | Cast a spell |
| `PING` | RTT measurement |

### Server → Client

| Type | Description |
|------|-------------|
| `HANDSHAKE_RESPONSE` | Auth result + assigned entity |
| `STATE_SNAPSHOT` | Entity positions (20Hz) |
| `ENTITY_SPAWN` / `ENTITY_DESPAWN` | Entity lifecycle |
| `TERRAFORM_APPLIED` | Voxel edit broadcast |
| `SPELL_CAST_EVENT` | Spell cast broadcast |
| `PROJECTILE_HIT` | Hit detection result |
| `NPC_EVENT` | NPC perception events |

## Spell System

Spells are user-created GDScript packages that run on all clients simultaneously.

### Creating a Spell

1. Use the in-game spell builder UI
2. Or manually create in `server_python/data/spells/<spell_id>/`

### Spell Execution

1. Client sends `SPELL_CAST_REQUEST` to game server
2. Server validates, generates deterministic seed
3. Server broadcasts `SPELL_CAST_EVENT` to all clients
4. All clients execute spell script with same seed → identical results

## Development

### Adding a New Message Type

1. Add to `Protocol.gd` enums
2. Add builder function
3. Add handler in `GameServer.gd` or `Net.gd`

### Running Multiple Clients

Launch multiple Godot instances - they'll connect to the same server and see each other.

### Building for Release

```powershell
cd scripts
.\package_game.ps1 -Platform windows
```

## Deployment

### Control Plane to Fly.io

```bash
cd server_python
fly deploy
```

### Game Servers

For production, game servers need to be managed (spawned on demand, health checked). The current implementation spawns them locally as child processes.

## License

MIT
