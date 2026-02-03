class_name WorldAPIAdapter
extends RefCounted

## Adapter providing a narrow, controlled interface for spells to interact with the world.
## This can later be extended to support server-authoritative validation.

## Reference to the actual scene tree for spawning
var _scene_root: Node = null

## Reference to the World autoload for world operations
var _world: Node = null

## Loaded assets from the spell package (path -> resource)
var _loaded_assets: Dictionary = {}

## Base path for loading spell assets
var _spell_cache_path: String = ""


func _init(scene_root: Node = null) -> void:
	_scene_root = scene_root
	if scene_root:
		_world = scene_root.get_node_or_null("/root/World")


## Set the spell cache path for asset loading
func set_spell_cache_path(cache_path: String) -> void:
	_spell_cache_path = cache_path


## Register a loaded asset for use
func register_asset(relative_path: String, resource: Resource) -> void:
	_loaded_assets[relative_path] = resource


## Get a loaded asset by relative path
func get_asset(relative_path: String) -> Resource:
	return _loaded_assets.get(relative_path)


# ============================================================================
# World Interaction Methods
# ============================================================================

## Spawn an entity/scene at a given transform
func spawn_entity(scene_path: String, transform: Transform3D, props: Dictionary = {}) -> Node:
	if not _scene_root:
		push_warning("[WorldAPI] No scene root set, cannot spawn entity")
		return null
	
	var scene: PackedScene = null
	
	# Check if it's a spell asset or a built-in scene
	if scene_path.begins_with("assets/"):
		# Try to load from spell cache
		scene = _loaded_assets.get(scene_path) as PackedScene
		if not scene:
			push_warning("[WorldAPI] Asset not loaded: ", scene_path)
			return null
	else:
		# Load from res://
		scene = load(scene_path) as PackedScene
		if not scene:
			push_warning("[WorldAPI] Failed to load scene: ", scene_path)
			return null
	
	var instance := scene.instantiate()
	instance.global_transform = transform
	
	# Apply custom properties
	for key in props:
		if instance.has_method("set_" + key):
			instance.call("set_" + key, props[key])
		elif key in instance:
			instance.set(key, props[key])
	
	_scene_root.add_child(instance)
	
	print("[WorldAPI] Spawned entity: ", scene_path)
	return instance


## Spawn a simple 3D node (for effects without pre-made scenes)
func spawn_simple_mesh(mesh: Mesh, transform: Transform3D, material: Material = null) -> MeshInstance3D:
	if not _scene_root:
		return null
	
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.global_transform = transform
	
	if material:
		mesh_instance.material_override = material
	
	_scene_root.add_child(mesh_instance)
	return mesh_instance


## Set a voxel value in the world (placeholder for voxel terrain integration)
func set_voxel(position: Vector3, value: int) -> bool:
	# This would integrate with VoxelTerrain if available
	print("[WorldAPI] set_voxel at ", position, " = ", value)
	
	# For now, send as world op if World is available
	if _world and _world.has_method("request_spell"):
		_world.request_spell({
			"type": "create_land" if value > 0 else "dig",
			"center": position,
			"radius": 2.0,
			"material_id": value
		})
		return true
	
	return false


## Set voxels in a region (batch operation)
func set_voxel_region(region_start: Vector3, region_end: Vector3, value: int) -> bool:
	print("[WorldAPI] set_voxel_region from ", region_start, " to ", region_end, " = ", value)
	return true


## Play a visual effect at a position
func play_vfx(asset_id: String, position: Vector3, params: Dictionary = {}) -> Node:
	print("[WorldAPI] play_vfx: ", asset_id, " at ", position)
	
	if not _scene_root:
		return null
	
	# Check for loaded VFX asset
	var vfx_resource = _loaded_assets.get("assets/" + asset_id)
	if vfx_resource:
		if vfx_resource is PackedScene:
			var instance = vfx_resource.instantiate()
			instance.global_position = position
			_scene_root.add_child(instance)
			return instance
	
	# Create a simple particle placeholder effect
	var effect := _create_simple_particle_effect(position, params)
	return effect


## Play a sound effect
func play_sound(asset_id: String, position: Vector3, params: Dictionary = {}) -> void:
	print("[WorldAPI] play_sound: ", asset_id, " at ", position)
	
	if not _scene_root:
		return
	
	# Check for loaded audio asset
	var audio_resource = _loaded_assets.get("assets/" + asset_id)
	
	var player := AudioStreamPlayer3D.new()
	player.global_position = position
	
	if audio_resource is AudioStream:
		player.stream = audio_resource
	else:
		# No audio loaded, just log
		player.queue_free()
		return
	
	player.volume_db = params.get("volume_db", 0.0)
	player.finished.connect(player.queue_free)
	
	_scene_root.add_child(player)
	player.play()


## Deal damage to an entity (placeholder)
func deal_damage(entity_id: String, amount: float, damage_type: String = "magic") -> bool:
	print("[WorldAPI] deal_damage to ", entity_id, ": ", amount, " (", damage_type, ")")
	# Would integrate with entity health system
	return true


## Query entities within a radius (placeholder)
func query_radius(position: Vector3, radius: float, _filter: Dictionary = {}) -> Array:
	print("[WorldAPI] query_radius at ", position, " r=", radius)
	# Would return entities in range
	return []


## Emit a custom event that other spells/systems can react to
func emit_event(event_name: String, event_data: Dictionary) -> void:
	print("[WorldAPI] emit_event: ", event_name, " data: ", event_data)
	# Would broadcast via event system


# ============================================================================
# Helper Methods
# ============================================================================

func _create_simple_particle_effect(position: Vector3, params: Dictionary) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.global_position = position
	particles.emitting = true
	particles.one_shot = true
	particles.explosiveness = 0.9
	particles.amount = params.get("amount", 16)
	particles.lifetime = params.get("lifetime", 0.5)
	
	# Create a simple process material
	var material := ParticleProcessMaterial.new()
	material.direction = Vector3.UP
	material.spread = 45.0
	material.initial_velocity_min = params.get("speed", 5.0)
	material.initial_velocity_max = params.get("speed", 5.0) * 1.5
	material.gravity = Vector3(0, -9.8, 0)
	material.color = params.get("color", Color.CYAN)
	
	particles.process_material = material
	
	# Create a simple mesh for particles
	var mesh := SphereMesh.new()
	mesh.radius = 0.1
	mesh.height = 0.2
	particles.draw_pass_1 = mesh
	
	# Auto-free after lifetime
	var timer := Timer.new()
	timer.wait_time = particles.lifetime + 0.5
	timer.one_shot = true
	timer.timeout.connect(func(): particles.queue_free())
	particles.add_child(timer)
	timer.start()
	
	if _scene_root:
		_scene_root.add_child(particles)
	
	return particles
