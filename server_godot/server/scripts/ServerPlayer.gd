extends Node3D
## Server-side player entity with authoritative physics.
## Movement is controlled entirely by server based on client inputs.

## Player configuration
@export var move_speed: float = 8.0
@export var sprint_multiplier: float = 1.8
@export var jump_force: float = 12.0
@export var gravity: float = 24.8
@export var max_health: float = 100.0
@export var fire_cooldown: float = 0.2

## Entity properties (set by EntityRegistry)
var entity_id: int = 0
var entity_type: int = Protocol.EntityType.PLAYER
var client_id: int = 0

## State
var velocity: Vector3 = Vector3.ZERO
var health: float = 100.0
var on_ground: bool = false

## Fire state
var _fire_timer: float = 0.0
var _last_fire_time: float = 0.0

## Physics
var _collision_shape: CollisionShape3D = null
var _body: CharacterBody3D = null


func _ready() -> void:
	# Create physics body for collision detection
	_body = CharacterBody3D.new()
	_body.name = "PhysicsBody"
	add_child(_body)
	
	# Create collision shape
	_collision_shape = CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	_collision_shape.shape = capsule
	_body.add_child(_collision_shape)
	
	# Sync body position
	_body.global_position = global_position


func apply_input(input, delta: float) -> void:
	"""Apply client input and simulate physics."""
	# Horizontal movement
	var move_dir := Vector3.ZERO
	if input.movement.length_squared() > 0.01:
		move_dir = input.movement.normalized()
		
		# Transform movement by aim direction (horizontal only)
		var aim_flat := Vector3(input.aim_direction.x, 0, input.aim_direction.z).normalized()
		if aim_flat.length_squared() > 0.01:
			var basis := Basis.looking_at(aim_flat, Vector3.UP)
			move_dir = basis * move_dir
	
	# Calculate target velocity
	var speed := move_speed
	if input.sprint:
		speed *= sprint_multiplier
	
	var target_velocity := move_dir * speed
	
	# Apply horizontal velocity with smoothing
	velocity.x = lerp(velocity.x, target_velocity.x, 10.0 * delta)
	velocity.z = lerp(velocity.z, target_velocity.z, 10.0 * delta)
	
	# Gravity
	velocity.y -= gravity * delta
	
	# Jump
	if input.jump and on_ground:
		velocity.y = jump_force
		on_ground = false
	
	# Move physics body
	_body.velocity = velocity
	_body.move_and_slide()
	
	# Update state from physics
	velocity = _body.velocity
	on_ground = _body.is_on_floor()
	
	# Sync position back
	global_position = _body.global_position
	
	# Update fire timer
	_fire_timer = max(0.0, _fire_timer - delta)


func can_fire() -> bool:
	"""Check if player can fire."""
	if _fire_timer > 0:
		return false
	_fire_timer = fire_cooldown
	_last_fire_time = Time.get_unix_time_from_system()
	return true


func take_damage(amount: float, source_entity_id: int = 0) -> void:
	"""Apply damage to player."""
	health = max(0.0, health - amount)
	print("[ServerPlayer %d] Took %.1f damage, health: %.1f" % [entity_id, amount, health])
	
	if health <= 0:
		_on_death(source_entity_id)


func _on_death(killer_entity_id: int) -> void:
	"""Handle player death."""
	print("[ServerPlayer %d] Died (killed by %d)" % [entity_id, killer_entity_id])
	# TODO: Respawn logic, notify clients, etc.
	health = max_health
	global_position = Vector3(0, 10, 0)
	velocity = Vector3.ZERO
	_body.global_position = global_position


func set_entity_id(id: int) -> void:
	"""Called by EntityRegistry."""
	entity_id = id


func get_state() -> Dictionary:
	"""Get serializable state."""
	return {
		"entity_id": entity_id,
		"client_id": client_id,
		"position": Protocol._vec3_to_array(global_position),
		"velocity": Protocol._vec3_to_array(velocity),
		"health": health,
		"on_ground": on_ground,
	}
