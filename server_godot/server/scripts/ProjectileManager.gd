extends Node
## Server-side projectile manager.
## Handles authoritative projectile simulation and hit detection.

signal projectile_hit(projectile_id: int, hit_entity_id: int, hit_point: Vector3, damage: float)

## Active projectiles
var _projectiles: Dictionary = {}  # projectile_id -> ProjectileData

## Next projectile ID
var _next_id: int = 1

## Reference to chunk manager for terrain collision
var _chunk_manager: Node = null


class ProjectileData:
	var projectile_id: int = 0
	var owner_entity_id: int = 0
	var position: Vector3 = Vector3.ZERO
	var direction: Vector3 = Vector3.FORWARD
	var speed: float = 50.0
	var damage: float = 10.0
	var lifetime: float = 5.0
	var spawn_tick: int = 0
	var radius: float = 0.1  # For sphere sweep


func _ready() -> void:
	print("[ProjectileManager] Initialized")
	
	# Get reference to chunk manager
	_chunk_manager = get_node_or_null("../ChunkManager")


func spawn_projectile(
	owner_entity_id: int,
	origin: Vector3,
	direction: Vector3,
	speed: float = 50.0,
	damage: float = 10.0,
	lifetime: float = 5.0
) -> int:
	"""Spawn a new projectile and return its ID."""
	var projectile := ProjectileData.new()
	projectile.projectile_id = _next_id
	projectile.owner_entity_id = owner_entity_id
	projectile.position = origin
	projectile.direction = direction.normalized()
	projectile.speed = speed
	projectile.damage = damage
	projectile.lifetime = lifetime
	projectile.spawn_tick = get_parent().server_tick if get_parent() and "server_tick" in get_parent() else 0
	
	_projectiles[_next_id] = projectile
	_next_id += 1
	
	print("[ProjectileManager] Spawned projectile %d from entity %d" % [projectile.projectile_id, owner_entity_id])
	return projectile.projectile_id


func simulate_tick(server_tick: int, delta: float) -> void:
	"""Simulate all projectiles for one tick."""
	var to_remove: Array = []
	
	for proj_id in _projectiles.keys():
		var proj: ProjectileData = _projectiles[proj_id]
		
		# Calculate movement
		var movement := proj.direction * proj.speed * delta
		var new_pos := proj.position + movement
		
		# Check for collisions
		var hit_result := _check_collision(proj, new_pos, server_tick)
		
		if hit_result["hit"]:
			# Hit something
			to_remove.append(proj_id)
			_on_projectile_hit(proj, hit_result, server_tick)
		else:
			# Update position
			proj.position = new_pos
			
			# Check lifetime
			proj.lifetime -= delta
			if proj.lifetime <= 0:
				to_remove.append(proj_id)
				_broadcast_despawn(proj_id, server_tick, "expired")
	
	# Remove finished projectiles
	for proj_id in to_remove:
		_projectiles.erase(proj_id)


func _check_collision(proj: ProjectileData, new_pos: Vector3, server_tick: int) -> Dictionary:
	"""Check projectile collision against entities and terrain."""
	var result := {"hit": false}
	
	# Get entity registry
	var entity_registry: Node = get_node_or_null("/root/EntityRegistry")
	if entity_registry == null:
		return result
	
	# Check entity collisions (simple sphere check)
	var entities: Dictionary = entity_registry.get_all_entities()
	for entity_id in entities.keys():
		# Skip owner
		if entity_id == proj.owner_entity_id:
			continue
		
		var entity: Node = entities[entity_id]
		if entity == null or not entity is Node3D:
			continue
		
		var entity_pos: Vector3 = entity.global_position
		var hit_radius: float = 1.0  # Entity hit radius
		
		# Check if projectile path intersects entity
		var closest := _closest_point_on_segment(proj.position, new_pos, entity_pos)
		var dist := closest.distance_to(entity_pos)
		
		if dist < hit_radius + proj.radius:
			result["hit"] = true
			result["entity_id"] = entity_id
			result["position"] = closest
			result["normal"] = (closest - entity_pos).normalized()
			return result
	
	# Check terrain collision
	if _chunk_manager:
		var terrain_hit: Dictionary = _chunk_manager.raycast_voxels(proj.position, proj.direction, proj.speed * 0.02)
		if terrain_hit.get("hit", false):
			result["hit"] = true
			result["entity_id"] = 0
			result["position"] = terrain_hit["position"]
			result["normal"] = terrain_hit["normal"]
			return result
	
	return result


func _closest_point_on_segment(seg_start: Vector3, seg_end: Vector3, point: Vector3) -> Vector3:
	"""Find closest point on line segment to a point."""
	var seg := seg_end - seg_start
	var seg_length_sq := seg.length_squared()
	
	if seg_length_sq < 0.0001:
		return seg_start
	
	var t := clampf((point - seg_start).dot(seg) / seg_length_sq, 0.0, 1.0)
	return seg_start + seg * t


func _on_projectile_hit(proj: ProjectileData, hit_result: Dictionary, server_tick: int) -> void:
	"""Handle projectile hit."""
	var hit_entity_id: int = hit_result.get("entity_id", 0)
	var hit_pos: Vector3 = hit_result.get("position", proj.position)
	var hit_normal: Vector3 = hit_result.get("normal", Vector3.UP)
	
	print("[ProjectileManager] Projectile %d hit entity %d at %s" % [proj.projectile_id, hit_entity_id, hit_pos])
	
	# Apply damage to hit entity
	if hit_entity_id > 0:
		var entity_registry: Node = get_node_or_null("/root/EntityRegistry")
		if entity_registry:
			var entity: Node = entity_registry.get_entity(hit_entity_id)
			if entity and entity.has_method("take_damage"):
				entity.take_damage(proj.damage, proj.owner_entity_id)
	
	# Emit signal
	projectile_hit.emit(proj.projectile_id, hit_entity_id, hit_pos, proj.damage)
	
	# Broadcast hit event
	_broadcast_hit(proj, hit_entity_id, hit_pos, hit_normal, server_tick)


func _broadcast_hit(proj: ProjectileData, hit_entity_id: int, hit_pos: Vector3, hit_normal: Vector3, server_tick: int) -> void:
	"""Broadcast projectile hit event to all clients."""
	var game_server := get_parent()
	if game_server == null or not game_server.has_method("_broadcast_message"):
		return
	
	var msg := Protocol.build_projectile_hit(
		server_tick,
		proj.projectile_id,
		hit_entity_id,
		hit_pos,
		hit_normal,
		proj.damage
	)
	game_server._broadcast_message(msg)


func _broadcast_despawn(projectile_id: int, server_tick: int, reason: String) -> void:
	"""Broadcast projectile despawn."""
	var game_server := get_parent()
	if game_server == null or not game_server.has_method("_broadcast_message"):
		return
	
	var msg := Protocol.build_entity_despawn(server_tick, projectile_id, reason)
	game_server._broadcast_message(msg)


func get_projectile_states() -> Array:
	"""Get all projectile states for snapshot."""
	var states: Array = []
	for proj_id in _projectiles.keys():
		var proj: ProjectileData = _projectiles[proj_id]
		states.append({
			"projectile_id": proj.projectile_id,
			"owner_entity_id": proj.owner_entity_id,
			"position": Protocol._vec3_to_array(proj.position),
			"direction": Protocol._vec3_to_array(proj.direction),
			"speed": proj.speed,
		})
	return states
