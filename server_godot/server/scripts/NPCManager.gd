extends Node
## Server-side NPC manager with perception (FOV, LOS).
## Handles NPC AI state and broadcasts detection events.

signal npc_spotted_player(npc_id: int, player_entity_id: int)
signal npc_lost_player(npc_id: int, player_entity_id: int)
signal npc_suspicion_changed(npc_id: int, player_entity_id: int, level: float)

## NPC data
var _npcs: Dictionary = {}  # entity_id -> NPCData

## Perception update rate (reduce CPU load)
const PERCEPTION_TICKS := 3  # Update perception every N ticks
var _perception_counter: int = 0


class NPCData:
	var entity_id: int = 0
	var entity_node: Node3D = null
	var fov_angle: float = 90.0  # Degrees
	var view_distance: float = 20.0
	var detection_state: int = Protocol.NPCDetectionState.IDLE
	var suspicion_level: float = 0.0
	var spotted_targets: Dictionary = {}  # entity_id -> detection_time
	var last_known_positions: Dictionary = {}  # entity_id -> Vector3
	
	## Detection thresholds
	var spot_threshold: float = 1.0  # Suspicion needed to spot
	var lose_threshold: float = 0.3  # Suspicion to lose target
	var suspicion_decay: float = 0.2  # Per second
	var suspicion_gain_rate: float = 2.0  # Per second when in view


func _ready() -> void:
	print("[NPCManager] Initialized")


func register_npc(entity_id: int, entity_node: Node3D, config: Dictionary = {}) -> void:
	"""Register an NPC for perception tracking."""
	var npc := NPCData.new()
	npc.entity_id = entity_id
	npc.entity_node = entity_node
	npc.fov_angle = config.get("fov_angle", 90.0)
	npc.view_distance = config.get("view_distance", 20.0)
	
	_npcs[entity_id] = npc
	print("[NPCManager] Registered NPC %d (FOV: %.1f°, Range: %.1f)" % [entity_id, npc.fov_angle, npc.view_distance])


func unregister_npc(entity_id: int) -> void:
	"""Unregister an NPC."""
	_npcs.erase(entity_id)


func simulate_tick(server_tick: int, delta: float, entity_registry: Node) -> void:
	"""Run perception simulation tick."""
	_perception_counter += 1
	
	if _perception_counter >= PERCEPTION_TICKS:
		_perception_counter = 0
		_update_perception(server_tick, delta * PERCEPTION_TICKS, entity_registry)


func _update_perception(server_tick: int, delta: float, entity_registry: Node) -> void:
	"""Update perception for all NPCs."""
	# Get all player entities
	var player_ids: Array = entity_registry.get_entities_by_type(Protocol.EntityType.PLAYER)
	
	for npc_id in _npcs.keys():
		var npc: NPCData = _npcs[npc_id]
		if npc.entity_node == null or not is_instance_valid(npc.entity_node):
			continue
		
		var npc_pos: Vector3 = npc.entity_node.global_position
		var npc_forward := -npc.entity_node.global_transform.basis.z
		
		# Check each player
		for player_id in player_ids:
			var player: Node3D = entity_registry.get_entity(player_id)
			if player == null:
				continue
			
			var player_pos: Vector3 = player.global_position
			var to_player := player_pos - npc_pos
			var distance := to_player.length()
			
			# Check if in range
			if distance > npc.view_distance:
				_decay_suspicion(npc, player_id, delta)
				continue
			
			# Check FOV
			var angle := rad_to_deg(npc_forward.angle_to(to_player.normalized()))
			if angle > npc.fov_angle * 0.5:
				_decay_suspicion(npc, player_id, delta)
				continue
			
			# Check line of sight (raycast)
			if not _check_line_of_sight(npc_pos + Vector3.UP * 1.5, player_pos + Vector3.UP * 0.5):
				_decay_suspicion(npc, player_id, delta)
				continue
			
			# Player is visible - increase suspicion
			_increase_suspicion(npc, player_id, delta, server_tick)
			npc.last_known_positions[player_id] = player_pos


func _check_line_of_sight(from: Vector3, to: Vector3) -> bool:
	"""Check if there's clear line of sight between two points."""
	# Get physics space
	var space_state := get_viewport().world_3d.direct_space_state if get_viewport() else null
	if space_state == null:
		return true  # Assume visible if no physics available
	
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1  # Environment layer
	
	var result := space_state.intersect_ray(query)
	return result.is_empty()


func _increase_suspicion(npc: NPCData, target_id: int, delta: float, server_tick: int) -> void:
	"""Increase suspicion for a target."""
	var old_suspicion: float = npc.spotted_targets.get(target_id, 0.0)
	var new_suspicion := minf(1.0, old_suspicion + npc.suspicion_gain_rate * delta)
	npc.spotted_targets[target_id] = new_suspicion
	
	var old_state := npc.detection_state
	
	# Check state transitions
	if new_suspicion >= npc.spot_threshold and old_suspicion < npc.spot_threshold:
		# Just spotted
		npc.detection_state = Protocol.NPCDetectionState.SPOTTED
		npc_spotted_player.emit(npc.entity_id, target_id)
		_broadcast_npc_event(server_tick, npc.entity_id, "spotted", target_id, npc.detection_state, new_suspicion)
		print("[NPCManager] NPC %d spotted player %d" % [npc.entity_id, target_id])
	elif new_suspicion >= 0.3 and old_suspicion < 0.3:
		# Becoming suspicious
		if npc.detection_state == Protocol.NPCDetectionState.IDLE:
			npc.detection_state = Protocol.NPCDetectionState.SUSPICIOUS
			npc_suspicion_changed.emit(npc.entity_id, target_id, new_suspicion)
			_broadcast_npc_event(server_tick, npc.entity_id, "suspicion_changed", target_id, npc.detection_state, new_suspicion)


func _decay_suspicion(npc: NPCData, target_id: int, delta: float) -> void:
	"""Decay suspicion for a target not in view."""
	if not npc.spotted_targets.has(target_id):
		return
	
	var old_suspicion: float = npc.spotted_targets[target_id]
	var new_suspicion := maxf(0.0, old_suspicion - npc.suspicion_decay * delta)
	
	if new_suspicion <= 0.0:
		npc.spotted_targets.erase(target_id)
		new_suspicion = 0.0
	else:
		npc.spotted_targets[target_id] = new_suspicion
	
	# Check state transitions
	if old_suspicion >= npc.spot_threshold and new_suspicion < npc.lose_threshold:
		# Lost target
		npc.detection_state = Protocol.NPCDetectionState.IDLE
		npc_lost_player.emit(npc.entity_id, target_id)
		# Get current server tick from parent
		var current_tick: int = get_parent().server_tick if get_parent() and "server_tick" in get_parent() else 0
		_broadcast_npc_event(current_tick, npc.entity_id, "lost", target_id, npc.detection_state, new_suspicion)
		print("[NPCManager] NPC %d lost player %d" % [npc.entity_id, target_id])


func _broadcast_npc_event(server_tick: int, npc_id: int, event_type: String, target_id: int, state: int, suspicion: float) -> void:
	"""Broadcast NPC event to clients."""
	var game_server := get_parent()
	if game_server == null or not game_server.has_method("_broadcast_message"):
		return
	
	var msg := Protocol.build_npc_event(server_tick, npc_id, event_type, target_id, state, suspicion)
	game_server._broadcast_message(msg)


func get_npc_state(npc_id: int) -> Dictionary:
	"""Get NPC perception state."""
	var npc: NPCData = _npcs.get(npc_id)
	if npc == null:
		return {}
	
	return {
		"entity_id": npc.entity_id,
		"detection_state": npc.detection_state,
		"suspicion_level": npc.suspicion_level,
		"spotted_targets": npc.spotted_targets.keys(),
	}


func get_all_npc_states() -> Array:
	"""Get states of all NPCs."""
	var states: Array = []
	for npc_id in _npcs.keys():
		states.append(get_npc_state(npc_id))
	return states
