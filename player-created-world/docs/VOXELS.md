# Voxel Terrain Integration

This document describes how to set up and use the voxel terrain system for live terraforming.

## Overview

The voxel system uses **Voxel Tools for Godot** (by Zylann), a GDExtension addon that provides high-performance editable voxel terrain. This integrates with our existing server-authoritative spell/ops pipeline.

### Architecture

```
Client                          Server
  |                               |
  |-- request_cast_spell() -->    |
  |                               | (validate, compile to ops)
  |<-- apply_op() broadcast ------|
  |                               |
  [VoxelBackend listens]          [op_log stored]
  [Edits VoxelTerrain]            [Late-join sync]
```

---

## Installation: Voxel Tools for Godot

### Option A: Download Pre-built Release (Recommended)

1. Go to: https://github.com/Zylann/godot_voxel/releases
2. Download the release matching your Godot version (e.g., `godot_voxel_v1.x_godot4.6.zip`)
3. Extract the `addons/zylann.voxel/` folder into `player-created-world/addons/`

Your folder structure should look like:
```
player-created-world/
├── addons/
│   └── zylann.voxel/
│       ├── voxel.gdextension
│       ├── bin/
│       │   ├── libvoxel.windows.x86_64.dll
│       │   ├── libvoxel.linux.x86_64.so
│       │   └── libvoxel.macos.universal.dylib
│       └── ...
├── client/
├── server/
└── ...
```

4. Restart Godot Editor to load the GDExtension.

### Option B: Build from Source

If no pre-built release matches your Godot version:

1. Clone the repository:
   ```bash
   git clone https://github.com/Zylann/godot_voxel.git
   cd godot_voxel
   git checkout <tag-for-your-godot-version>
   ```

2. Follow build instructions at: https://voxel-tools.readthedocs.io/en/latest/getting_started/building/

3. Copy the resulting `addons/zylann.voxel/` folder to `player-created-world/addons/`

### Verify Installation

After installation, open the project in Godot. You should see these nodes available when adding a new node:
- `VoxelTerrain`
- `VoxelLodTerrain`
- `VoxelMesher*`
- `VoxelGenerator*`

---

## Version Constraints

| Component | Version |
|-----------|---------|
| Godot Engine | 4.6+ |
| Voxel Tools | 1.2+ (must match Godot version) |

**Important**: Voxel Tools releases are tied to specific Godot versions. Always download the release that matches your Godot version exactly.

---

## Running the Demo

### Method 1: Single Process (Development)

1. Open the project in Godot Editor
2. Run `client/scenes/Main.tscn`
3. Press **F1** to start a local server
4. Press **1** to create land (add_sphere at camera target)
5. Press **2** to dig (subtract_sphere at camera target)

### Method 2: Separate Server + Client

**Terminal 1 - Server:**
```bash
cd player-created-world
godot --headless --main-scene server/scenes/ServerMain.tscn
```

**Terminal 2 - Client:**
```bash
cd player-created-world
godot --main-scene client/scenes/Main.tscn
```

Or use the provided scripts:
```bash
./tools/run_server.sh   # Starts headless server
./tools/run_client.sh   # Starts client
```

### Method 3: Two Clients (One Hosts)

1. Run two instances of `client/scenes/Main.tscn`
2. In Instance 1: Press **F1** to host
3. In Instance 2: Press **F2** to connect
4. Both instances can now terraform and see each other's changes

---

## Controls

| Key | Action |
|-----|--------|
| F1 | Start server (host locally) |
| F2 | Connect to server |
| 1 | Cast "create_land" spell (add_sphere) |
| 2 | Cast "dig" spell (subtract_sphere) |
| WASD | Move camera |
| Mouse | Look around |
| Shift | Move faster |

---

## How It Works

### Spell → Op → Voxel Pipeline

1. **Client Input**: Player presses a key to cast a spell
2. **Spell Request**: `World.request_cast_spell(spell)` RPC to server (peer 1)
3. **Server Compilation**: `SpellOps.compile_spell_to_ops()` converts spell to ops
4. **Broadcast**: Server calls `World.apply_op.rpc(op)` to all peers
5. **Signal**: `World.op_applied` signal emitted on all peers
6. **Voxel Backend**: `VoxelBackend` listens and applies edits to `VoxelTerrain`

### Late-Join Sync

When a client connects:
1. Server detects connection via `multiplayer.peer_connected`
2. Server sends `World.op_log` to the new client
3. Client replays all ops to reconstruct current terrain state

This ensures all clients see the same world state regardless of when they joined.

### Server Authority

- **Clients** only send *intent* (spell requests)
- **Server** validates, compiles, and broadcasts *ops*
- **Clients** apply ops locally for visuals
- Server maintains `op_log` as canonical history

---

## Customization

### Adjusting Brush Size

Edit the spell parameters in `ClientController.gd`:

```gdscript
var spell := {
    "type": "create_land",
    "center": target_position,
    "radius": 10.0,        # Change brush size
    "material_id": 1       # Material/voxel type
}
```

### Adding New Op Types

1. Add compilation logic in `SpellOps.gd`:
   ```gdscript
   elif t == "my_new_spell":
       return [{"op": "my_new_op", ...}]
   ```

2. Handle the op in `VoxelBackend.gd`:
   ```gdscript
   "my_new_op":
       _apply_my_new_op(op)
   ```

### Changing Materials/Voxel Types

The `material_id` in ops maps to voxel values:
- `0` = Air (empty)
- `1` = Solid (default terrain)
- `2+` = Custom materials (configure in VoxelMesher)

---

## Fallback Visualizer

If Voxel Tools is not installed, `VoxelBackend` automatically uses a **fallback CSG visualizer** for testing:

- Creates CSGSphere3D nodes to represent add/subtract operations
- Shows approximately where terrain edits would occur
- Useful for testing the network/op pipeline without the addon

**Note**: The fallback is NOT a real voxel system. It:
- Doesn't properly subtract (just shows transparent spheres)
- Doesn't merge geometry
- Is slower than real voxel terrain

To test with fallback:
1. Skip Voxel Tools installation
2. Run the demo as normal
3. You'll see CSG spheres appear when pressing 1/2

Console will show:
```
[VoxelBackend] Ready. Using fallback CSG visualizer.
[VoxelBackend] NOTE: Install Voxel Tools addon for proper terrain!
```

---

## Troubleshooting

### "VoxelTerrain" node not found
- Ensure Voxel Tools addon is correctly installed in `addons/zylann.voxel/`
- Restart Godot Editor after installation
- Check that `.gdextension` file exists and paths are correct

### Terrain not updating
- Verify `World.op_applied` signal is connected in `VoxelBackend._ready()`
- Check console for errors during `apply_sphere_edit()`
- Ensure voxel terrain bounds include the edit location

### Late-join client shows empty world
- Verify server is calling `_send_op_log_to_peer()` on connection
- Check network connectivity between server and client
- Look for RPC errors in console

### Performance issues with large edits
- Reduce `radius` in spell parameters
- The system uses `VoxelTool.do_sphere()` which is optimized for brush edits
- For very large terraforming, consider batching ops

---

## Files Reference

| File | Purpose |
|------|---------|
| `shared/scripts/world/VoxelBackend.gd` | Applies ops to voxel terrain |
| `shared/scripts/world/World.gd` | Server-authoritative op pipeline |
| `shared/scripts/spells/SpellOps.gd` | Compiles spells to ops |
| `client/scenes/Main.tscn` | Client scene with VoxelTerrain |
| `client/scripts/ClientController.gd` | Player input and spell casting |
