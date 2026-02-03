extends Node
## Shared network protocol definitions for client-server communication.
## This file defines the message schema and utilities used by both server and client.

## Protocol version - increment when making breaking changes
const PROTOCOL_VERSION := 1

## Tick rate configuration
const SERVER_TICK_RATE := 60  ## Physics ticks per second
const SNAPSHOT_RATE := 20  ## Snapshots per second (every 3 ticks at 60hz)
const TICKS_PER_SNAPSHOT := SERVER_TICK_RATE / SNAPSHOT_RATE

## Message types - Client to Server
enum ClientMsg {
	HANDSHAKE = 1,
	INPUT_FRAME = 2,
	TERRAFORM_REQUEST = 3,
	CHUNK_REQUEST = 4,
	PING = 5,
	DISCONNECT = 6,
	SPELL_CAST_REQUEST = 7,
}

## Message types - Server to Client
enum ServerMsg {
	HANDSHAKE_RESPONSE = 100,
	STATE_SNAPSHOT = 101,
	ENTITY_SPAWN = 102,
	ENTITY_DESPAWN = 103,
	PROJECTILE_HIT = 104,
	NPC_EVENT = 105,
	TERRAFORM_APPLIED = 106,
	CHUNK_DATA = 107,
	PONG = 108,
	ERROR = 109,
	PLAYER_JOINED = 110,
	PLAYER_LEFT = 111,
	SPELL_CAST_EVENT = 112,
}

## Entity types
enum EntityType {
	PLAYER = 1,
	NPC = 2,
	PROJECTILE = 3,
	PROP = 4,
}

## NPC detection states
enum NPCDetectionState {
	IDLE = 0,
	SUSPICIOUS = 1,
	SPOTTED = 2,
}

## Terraform operation types
enum TerraformOp {
	SPHERE_ADD = 1,
	SPHERE_SUB = 2,
	PAINT = 3,
}

# =============================================================================
# Message Builders - Client to Server
# =============================================================================

static func build_handshake(session_token: String, client_id: String, protocol_version: int = PROTOCOL_VERSION) -> Dictionary:
	"""Build handshake message for initial connection."""
	return {
		"type": ClientMsg.HANDSHAKE,
		"protocol_version": protocol_version,
		"session_token": session_token,
		"client_id": client_id,
		"timestamp": Time.get_unix_time_from_system(),
	}


static func build_input_frame(
	client_tick: int,
	server_tick_ack: int,
	sequence_id: int,
	movement: Vector3,
	aim_direction: Vector3,
	sprint: bool = false,
	fire: bool = false,
	interact: bool = false,
	jump: bool = false
) -> Dictionary:
	"""Build input frame message sent each client tick."""
	return {
		"type": ClientMsg.INPUT_FRAME,
		"client_tick": client_tick,
		"server_tick_ack": server_tick_ack,
		"sequence_id": sequence_id,
		"movement": _vec3_to_array(movement),
		"aim_direction": _vec3_to_array(aim_direction),
		"sprint": sprint,
		"fire": fire,
		"interact": interact,
		"jump": jump,
	}


static func build_terraform_request(
	op_type: TerraformOp,
	center: Vector3,
	radius: float,
	material_id: int = 1,
	client_sequence_id: int = 0
) -> Dictionary:
	"""Build terraform request message."""
	return {
		"type": ClientMsg.TERRAFORM_REQUEST,
		"op_type": op_type,
		"center": _vec3_to_array(center),
		"radius": radius,
		"material_id": material_id,
		"client_sequence_id": client_sequence_id,
	}


static func build_chunk_request(chunk_id: Array, last_known_version: int = 0) -> Dictionary:
	"""Build chunk data request."""
	return {
		"type": ClientMsg.CHUNK_REQUEST,
		"chunk_id": chunk_id,  # [cx, cy, cz]
		"last_known_version": last_known_version,
	}


static func build_ping(client_time: float) -> Dictionary:
	"""Build ping message for RTT measurement."""
	return {
		"type": ClientMsg.PING,
		"client_time": client_time,
	}


static func build_spell_cast_request(
	spell_id: String,
	revision_id: String,
	target_position: Vector3,
	target_entity_id: int = 0,
	extra_params: Dictionary = {}
) -> Dictionary:
	"""Build spell cast request."""
	return {
		"type": ClientMsg.SPELL_CAST_REQUEST,
		"spell_id": spell_id,
		"revision_id": revision_id,
		"target_position": _vec3_to_array(target_position),
		"target_entity_id": target_entity_id,
		"extra_params": extra_params,
	}

# =============================================================================
# Message Builders - Server to Client
# =============================================================================

static func build_handshake_response(
	success: bool,
	server_tick: int,
	assigned_entity_id: int = 0,
	world_id: String = "",
	error: String = ""
) -> Dictionary:
	"""Build handshake response."""
	return {
		"type": ServerMsg.HANDSHAKE_RESPONSE,
		"success": success,
		"server_tick": server_tick,
		"assigned_entity_id": assigned_entity_id,
		"world_id": world_id,
		"error": error,
	}


static func build_state_snapshot(
	server_tick: int,
	entities: Array,  # Array of entity state dicts
	player_state: Dictionary = {},  # Additional state for the receiving player
) -> Dictionary:
	"""Build state snapshot message."""
	return {
		"type": ServerMsg.STATE_SNAPSHOT,
		"server_tick": server_tick,
		"entities": entities,
		"player_state": player_state,
	}


static func build_entity_spawn(
	server_tick: int,
	entity_id: int,
	entity_type: EntityType,
	position: Vector3,
	rotation: Vector3 = Vector3.ZERO,
	properties: Dictionary = {}
) -> Dictionary:
	"""Build entity spawn message."""
	return {
		"type": ServerMsg.ENTITY_SPAWN,
		"server_tick": server_tick,
		"entity_id": entity_id,
		"entity_type": entity_type,
		"position": _vec3_to_array(position),
		"rotation": _vec3_to_array(rotation),
		"properties": properties,
	}


static func build_entity_despawn(server_tick: int, entity_id: int, reason: String = "") -> Dictionary:
	"""Build entity despawn message."""
	return {
		"type": ServerMsg.ENTITY_DESPAWN,
		"server_tick": server_tick,
		"entity_id": entity_id,
		"reason": reason,
	}


static func build_projectile_hit(
	server_tick: int,
	projectile_id: int,
	hit_entity_id: int = 0,
	hit_point: Vector3 = Vector3.ZERO,
	hit_normal: Vector3 = Vector3.UP,
	damage: float = 0.0
) -> Dictionary:
	"""Build projectile hit event."""
	return {
		"type": ServerMsg.PROJECTILE_HIT,
		"server_tick": server_tick,
		"projectile_id": projectile_id,
		"hit_entity_id": hit_entity_id,
		"hit_point": _vec3_to_array(hit_point),
		"hit_normal": _vec3_to_array(hit_normal),
		"damage": damage,
	}


static func build_npc_event(
	server_tick: int,
	npc_id: int,
	event_type: String,  # "spotted", "lost", "suspicion_changed"
	target_entity_id: int = 0,
	detection_state: NPCDetectionState = NPCDetectionState.IDLE,
	suspicion_level: float = 0.0
) -> Dictionary:
	"""Build NPC perception event."""
	return {
		"type": ServerMsg.NPC_EVENT,
		"server_tick": server_tick,
		"npc_id": npc_id,
		"event_type": event_type,
		"target_entity_id": target_entity_id,
		"detection_state": detection_state,
		"suspicion_level": suspicion_level,
	}


static func build_terraform_applied(
	server_tick: int,
	op_type: TerraformOp,
	center: Vector3,
	radius: float,
	material_id: int,
	affected_chunks: Array,  # Array of {chunk_id, new_version}
	client_sequence_id: int = 0
) -> Dictionary:
	"""Build terraform applied event."""
	return {
		"type": ServerMsg.TERRAFORM_APPLIED,
		"server_tick": server_tick,
		"op_type": op_type,
		"center": _vec3_to_array(center),
		"radius": radius,
		"material_id": material_id,
		"affected_chunks": affected_chunks,
		"client_sequence_id": client_sequence_id,
	}


static func build_chunk_data(
	chunk_id: Array,
	version: int,
	data: PackedByteArray,
	compressed: bool = false
) -> Dictionary:
	"""Build chunk data response."""
	return {
		"type": ServerMsg.CHUNK_DATA,
		"chunk_id": chunk_id,
		"version": version,
		"data": Marshalls.raw_to_base64(data),
		"compressed": compressed,
	}


static func build_pong(client_time: float, server_time: float, server_tick: int) -> Dictionary:
	"""Build pong response."""
	return {
		"type": ServerMsg.PONG,
		"client_time": client_time,
		"server_time": server_time,
		"server_tick": server_tick,
	}


static func build_error(error_code: int, message: String) -> Dictionary:
	"""Build error message."""
	return {
		"type": ServerMsg.ERROR,
		"error_code": error_code,
		"message": message,
	}


static func build_spell_cast_event(
	server_tick: int,
	spell_id: String,
	revision_id: String,
	caster_entity_id: int,
	target_position: Vector3,
	seed: int,
	extra_params: Dictionary = {}
) -> Dictionary:
	"""Build spell cast event broadcast to all clients."""
	return {
		"type": ServerMsg.SPELL_CAST_EVENT,
		"server_tick": server_tick,
		"spell_id": spell_id,
		"revision_id": revision_id,
		"caster_entity_id": caster_entity_id,
		"target_position": _vec3_to_array(target_position),
		"seed": seed,
		"extra_params": extra_params,
	}

# =============================================================================
# Entity State Serialization
# =============================================================================

static func serialize_entity_state(
	entity_id: int,
	entity_type: EntityType,
	position: Vector3,
	rotation: Vector3,
	velocity: Vector3 = Vector3.ZERO,
	health: float = 100.0,
	extra: Dictionary = {}
) -> Dictionary:
	"""Serialize entity state for snapshots."""
	var state := {
		"id": entity_id,
		"t": entity_type,  # Short key to save bandwidth
		"p": _vec3_to_array(position),
		"r": _vec3_to_array(rotation),
		"v": _vec3_to_array(velocity),
		"h": health,
	}
	if not extra.is_empty():
		state["x"] = extra
	return state


static func deserialize_entity_state(data: Dictionary) -> Dictionary:
	"""Deserialize entity state from snapshot."""
	return {
		"entity_id": data.get("id", 0),
		"entity_type": data.get("t", EntityType.PLAYER),
		"position": _array_to_vec3(data.get("p", [0, 0, 0])),
		"rotation": _array_to_vec3(data.get("r", [0, 0, 0])),
		"velocity": _array_to_vec3(data.get("v", [0, 0, 0])),
		"health": data.get("h", 100.0),
		"extra": data.get("x", {}),
	}

# =============================================================================
# Player State (for reconciliation)
# =============================================================================

static func serialize_player_state(
	last_processed_sequence_id: int,
	position: Vector3,
	velocity: Vector3,
	on_ground: bool = true
) -> Dictionary:
	"""Serialize authoritative player state for client reconciliation."""
	return {
		"seq": last_processed_sequence_id,
		"p": _vec3_to_array(position),
		"v": _vec3_to_array(velocity),
		"g": on_ground,
	}

# =============================================================================
# Utility Functions
# =============================================================================

static func _vec3_to_array(v: Vector3) -> Array:
	"""Convert Vector3 to array for JSON serialization."""
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]


static func _array_to_vec3(a: Array) -> Vector3:
	"""Convert array to Vector3."""
	if a.size() < 3:
		return Vector3.ZERO
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func encode_message(data: Dictionary) -> String:
	"""Encode message to JSON string."""
	return JSON.stringify(data)


static func decode_message(json_str: String) -> Dictionary:
	"""Decode message from JSON string."""
	var json := JSON.new()
	var err := json.parse(json_str)
	if err != OK:
		push_error("[Protocol] Failed to parse message: %s" % json_str.substr(0, 100))
		return {}
	return json.data if json.data is Dictionary else {}


static func get_message_type(data: Dictionary) -> int:
	"""Get message type from decoded message."""
	return int(data.get("type", 0))
