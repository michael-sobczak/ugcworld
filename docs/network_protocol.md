# Network Protocol Specification

This document describes the network protocol used for client-server communication in UGC World.

## Overview

The architecture uses a hybrid approach:
- **Control Plane (Python)**: Handles authentication, matchmaking, and persistence
- **Game Server (Godot Headless)**: Handles authoritative game simulation
- **Client (Godot)**: Handles input, prediction, and rendering

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   ┌─────────┐     HTTP/REST      ┌─────────────────────┐   │
│   │ Client  │◄──────────────────►│   Control Plane     │   │
│   │ (Godot) │                    │     (Python)        │   │
│   └────┬────┘                    └──────────┬──────────┘   │
│        │                                    │               │
│        │  WebSocket                         │ spawn/stop   │
│        │  (game protocol)                   │               │
│        ▼                                    ▼               │
│   ┌─────────────────────────────────────────────────────┐   │
│   │              Game Server (Godot Headless)           │   │
│   │        Authoritative simulation @ 60 Hz             │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Protocol Version

Current version: **1**

All messages include a `protocol_version` field in the handshake. Clients and servers must match protocol versions.

## Message Format

All messages are JSON-encoded over WebSocket.

```json
{
    "type": <message_type_int>,
    // ... message-specific fields
}
```

## Message Types

### Client → Server

| Type | Name | Description |
|------|------|-------------|
| 1 | HANDSHAKE | Initial authentication |
| 2 | INPUT_FRAME | Player input for simulation |
| 3 | TERRAFORM_REQUEST | Request voxel modification |
| 4 | CHUNK_REQUEST | Request chunk data |
| 5 | PING | RTT measurement |
| 6 | DISCONNECT | Clean disconnect |

### Server → Client

| Type | Name | Description |
|------|------|-------------|
| 100 | HANDSHAKE_RESPONSE | Auth result + entity assignment |
| 101 | STATE_SNAPSHOT | Periodic entity state update |
| 102 | ENTITY_SPAWN | New entity created |
| 103 | ENTITY_DESPAWN | Entity removed |
| 104 | PROJECTILE_HIT | Projectile hit event |
| 105 | NPC_EVENT | NPC perception event |
| 106 | TERRAFORM_APPLIED | Voxel modification applied |
| 107 | CHUNK_DATA | Chunk voxel data |
| 108 | PONG | RTT response |
| 109 | ERROR | Error message |
| 110 | PLAYER_JOINED | Player connected |
| 111 | PLAYER_LEFT | Player disconnected |

## Message Schemas

### Client Messages

#### HANDSHAKE (type: 1)

Sent immediately after WebSocket connection.

```json
{
    "type": 1,
    "protocol_version": 1,
    "session_token": "token_from_control_plane",
    "client_id": "client_abc123",
    "timestamp": 1704067200.0
}
```

#### INPUT_FRAME (type: 2)

Sent every physics tick (60 Hz) with current input state.

```json
{
    "type": 2,
    "client_tick": 12345,
    "server_tick_ack": 12300,
    "sequence_id": 500,
    "movement": [0.0, 0.0, -1.0],
    "aim_direction": [0.0, 0.0, -1.0],
    "sprint": false,
    "fire": false,
    "interact": false,
    "jump": false
}
```

**Fields:**
- `client_tick`: Local physics frame counter
- `server_tick_ack`: Last received server tick (for lag compensation)
- `sequence_id`: Monotonically increasing input ID (for reconciliation)
- `movement`: [x, y, z] input vector (-1 to 1)
- `aim_direction`: [x, y, z] normalized look direction
- `sprint`, `fire`, `interact`, `jump`: Boolean action flags

#### TERRAFORM_REQUEST (type: 3)

Request voxel terrain modification.

```json
{
    "type": 3,
    "op_type": 1,
    "center": [10.0, 5.0, 20.0],
    "radius": 3.0,
    "material_id": 1,
    "client_sequence_id": 42
}
```

**op_type values:**
- 1: SPHERE_ADD - Add terrain
- 2: SPHERE_SUB - Remove terrain
- 3: PAINT - Change material

#### CHUNK_REQUEST (type: 4)

Request chunk data for specified coordinates.

```json
{
    "type": 4,
    "chunk_id": [0, 0, 0],
    "last_known_version": 5
}
```

#### PING (type: 5)

RTT measurement.

```json
{
    "type": 5,
    "client_time": 1704067200.123
}
```

### Server Messages

#### HANDSHAKE_RESPONSE (type: 100)

Response to client handshake.

```json
{
    "type": 100,
    "success": true,
    "server_tick": 50000,
    "assigned_entity_id": 42,
    "world_id": "world_abc123",
    "error": ""
}
```

#### STATE_SNAPSHOT (type: 101)

Periodic state update sent at 20 Hz.

```json
{
    "type": 101,
    "server_tick": 50100,
    "entities": [
        {
            "id": 42,
            "t": 1,
            "p": [10.5, 0.0, 20.3],
            "r": [0.0, 1.57, 0.0],
            "v": [2.0, 0.0, -1.0],
            "h": 100.0
        }
    ],
    "player_state": {
        "seq": 495,
        "p": [10.5, 0.0, 20.3],
        "v": [2.0, 0.0, -1.0],
        "g": true
    }
}
```

**Entity state fields (compact keys for bandwidth):**
- `id`: Entity ID
- `t`: Entity type (1=Player, 2=NPC, 3=Projectile, 4=Prop)
- `p`: Position [x, y, z]
- `r`: Rotation [x, y, z] (euler)
- `v`: Velocity [x, y, z]
- `h`: Health

**Player state fields:**
- `seq`: Last processed input sequence ID
- `p`: Authoritative position
- `v`: Authoritative velocity
- `g`: On ground flag

#### ENTITY_SPAWN (type: 102)

New entity created.

```json
{
    "type": 102,
    "server_tick": 50150,
    "entity_id": 100,
    "entity_type": 3,
    "position": [15.0, 1.5, 25.0],
    "rotation": [0.0, 0.0, 0.0],
    "properties": {
        "direction": [1.0, 0.0, 0.0],
        "owner": 42
    }
}
```

#### ENTITY_DESPAWN (type: 103)

Entity removed.

```json
{
    "type": 103,
    "server_tick": 50200,
    "entity_id": 100,
    "reason": "expired"
}
```

#### PROJECTILE_HIT (type: 104)

Server-authoritative hit detection result.

```json
{
    "type": 104,
    "server_tick": 50180,
    "projectile_id": 100,
    "hit_entity_id": 50,
    "hit_point": [18.0, 1.2, 25.0],
    "hit_normal": [-1.0, 0.0, 0.0],
    "damage": 10.0
}
```

#### NPC_EVENT (type: 105)

NPC perception state change.

```json
{
    "type": 105,
    "server_tick": 50300,
    "npc_id": 60,
    "event_type": "spotted",
    "target_entity_id": 42,
    "detection_state": 2,
    "suspicion_level": 1.0
}
```

**event_type values:** `"spotted"`, `"lost"`, `"suspicion_changed"`

**detection_state values:** 0=Idle, 1=Suspicious, 2=Spotted

#### TERRAFORM_APPLIED (type: 106)

Voxel modification confirmed.

```json
{
    "type": 106,
    "server_tick": 50400,
    "op_type": 1,
    "center": [10.0, 5.0, 20.0],
    "radius": 3.0,
    "material_id": 1,
    "affected_chunks": [
        {"chunk_id": [0, 0, 0], "new_version": 6}
    ],
    "client_sequence_id": 42
}
```

#### CHUNK_DATA (type: 107)

Chunk voxel data response.

```json
{
    "type": 107,
    "chunk_id": [0, 0, 0],
    "version": 6,
    "data": "base64_encoded_gzip_compressed_voxels",
    "compressed": true
}
```

#### PONG (type: 108)

RTT response.

```json
{
    "type": 108,
    "client_time": 1704067200.123,
    "server_time": 1704067200.145,
    "server_tick": 50500
}
```

## Timing and Tick Rates

| Component | Rate | Notes |
|-----------|------|-------|
| Server physics tick | 60 Hz | Fixed timestep simulation |
| Snapshot broadcast | 20 Hz | Every 3 physics ticks |
| Client input send | 60 Hz | Every physics frame |
| Ping interval | 1 Hz | RTT measurement |

## Client-Side Prediction and Reconciliation

### Prediction Flow

1. Client gathers input each physics frame
2. Client applies input to local simulation (prediction)
3. Client sends INPUT_FRAME to server
4. Client stores input + predicted state in buffer

### Reconciliation Flow

1. Server processes input and simulates authoritatively
2. Server sends STATE_SNAPSHOT with `last_processed_sequence_id`
3. Client receives snapshot:
   - Discards acknowledged inputs from buffer
   - Compares predicted position to server position
   - If difference > threshold:
     - Resets to server position
     - Replays unacknowledged inputs
     - Smoothly corrects visual position

### Thresholds

- **Correction threshold**: 0.5 units - trigger reconciliation
- **Snap threshold**: 3.0 units - instant teleport (large desync)

## Entity Interpolation

Non-local entities use interpolation for smooth movement:

1. Client stores received states in buffer
2. Render time = current time - interpolation delay (150ms)
3. Find two states bracketing render time
4. Linear interpolate between states

## Error Handling

### Connection Errors

If WebSocket disconnects:
1. Client attempts reconnection to game server
2. If fails 3 times, return to control plane for new assignment

### Protocol Errors

Server sends ERROR (type: 109) for invalid messages:

```json
{
    "type": 109,
    "error_code": 1,
    "message": "Invalid message format"
}
```

## Security Considerations

- Session tokens validated on handshake
- Server never trusts client positions
- All game state changes require server validation
- Rate limiting on terraform requests (future)

## Future Considerations

- Binary protocol (MessagePack/Protocol Buffers) for bandwidth
- Delta compression for snapshots
- Interest management for large worlds
- UDP transport for lower latency
