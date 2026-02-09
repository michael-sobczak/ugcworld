extends Node

## Client controller for terraforming and spell casting demo.
## Connects to the Python backend server and manages world selection.
##
## Controls:
## - C or Enter: Open connection dialog (choose localhost/production/custom)
## - W: Open world selection dialog (when connected but not in a world)
## - S: Open spell creation model selection dialog
## - 1: Cast create_land spell (legacy voxel op)
## - 2: Cast dig spell (legacy voxel op)
## - 3: Cast demo_spark spell (new spell system)
## - 4: Cast demo_spawn spell (new spell system)
## - 5: Build a new demo_spark revision
## - 6: Build a new demo_spawn revision
## - 7: Publish demo_spark to beta
## - 8: Publish demo_spawn to beta
## - WASD: Move camera
## - Right-click: Toggle mouse look
## - Shift: Move faster

## Camera settings
@export var move_speed: float = 20.0
@export var fast_move_multiplier: float = 3.0
@export var mouse_sensitivity: float = 0.003
@export var drag_move_speed: float = 0.02
@export var scroll_zoom_speed: float = 4.0
@export var zoom_smoothness: float = 10.0
@export var move_smoothness: float = 12.0
@export var rotate_smoothness: float = 18.0

## Spell settings
@export var default_brush_radius: float = 8.0
@export var cast_distance: float = 30.0

## Server settings
@export var server_host: String = "127.0.0.1"
@export var server_port: int = 5000
@export var auto_connect: bool = false  # Manual auto-connect (for testing)

## Production server URL (used in release builds)
const PRODUCTION_URL := "wss://ugc-world-backend.fly.dev"

## References
var camera: Camera3D = null
var net_node: Node = null
var world_node: Node = null
var spell_net: Node = null
var spell_cast: Node = null
var spell_registry: Node = null
var connection_dialog: Node = null
var world_selection_dialog: Node = null
var model_selection_dialog: Node = null
var spell_creation_screen: Node = null

## State
var _mouse_captured: bool = false
var _camera_rotation: Vector2 = Vector2.ZERO
var _dragging_left: bool = false
var _dragging_right: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO
var _default_camera_transform: Transform3D
var _target_camera_pos: Vector3 = Vector3.ZERO
var _target_camera_rot: Vector2 = Vector2.ZERO

## Track latest built revisions for publishing
var _latest_revisions: Dictionary = {}  # spell_id -> revision_id


func _ready() -> void:
	# Get autoload references
	net_node = get_node_or_null("/root/Net")
	world_node = get_node_or_null("/root/World")
	spell_net = get_node_or_null("/root/SpellNet")
	spell_cast = get_node_or_null("/root/SpellCastController")
	spell_registry = get_node_or_null("/root/SpellRegistry")
	
	# Find camera in scene
	camera = get_viewport().get_camera_3d()
	if camera:
		_default_camera_transform = camera.global_transform
		var euler = camera.global_transform.basis.get_euler()
		_camera_rotation = Vector2(euler.y, euler.x)
		_target_camera_pos = camera.global_position
		_target_camera_rot = _camera_rotation
	
	# Find connection dialog in scene
	connection_dialog = get_node_or_null("../ConnectionDialog")
	if connection_dialog:
		connection_dialog.connection_requested.connect(_on_connection_url_requested)
	
	# Find world selection dialog in scene
	world_selection_dialog = get_node_or_null("../WorldSelectionDialog")
	if world_selection_dialog:
		world_selection_dialog.world_selected.connect(_on_world_selected)
	
	# Find spell creation UI in scene
	model_selection_dialog = get_node_or_null("../ModelSelectionDialog")
	if model_selection_dialog:
		model_selection_dialog.model_selected.connect(_on_model_selected)
	
	spell_creation_screen = get_node_or_null("../SpellCreationScreen")
	
	# Connect to network signals
	if net_node:
		net_node.connected_to_control_plane.connect(_on_connected_to_control_plane)
		net_node.authenticated.connect(_on_authenticated)
		net_node.connected_to_game_server.connect(_on_connected)
		net_node.disconnected_from_server.connect(_on_disconnected)
		net_node.connection_failed.connect(_on_connection_failed)
		net_node.world_joined.connect(_on_world_joined)
		net_node.world_left.connect(_on_world_left)
	
	# Connect to world signals
	if world_node:
		world_node.sync_complete.connect(_on_sync_complete)
		world_node.spell_rejected.connect(_on_spell_rejected)
	
	# Connect to spell system signals
	if spell_net:
		spell_net.job_progress.connect(_on_job_progress)
		spell_net.build_started.connect(_on_build_started)
		spell_net.spell_active_update.connect(_on_spell_active_update)
		spell_net.server_error.connect(_on_spell_error)
	
	if spell_cast:
		spell_cast.scene_root = get_parent()  # Set scene root for spawning
		spell_cast.spell_cast_complete.connect(_on_spell_cast_complete)
		spell_cast.spell_cast_failed.connect(_on_spell_cast_failed)
	
	# Auto-connect behavior:
	# - In release builds (standalone), always auto-connect to production
	# - In editor, use manual dialog unless auto_connect is enabled
	if _is_release_build():
		print("[Client] Release build detected - connecting to production server...")
		call_deferred("_connect_to_production")
	elif auto_connect:
		call_deferred("_connect_to_server")
	else:
		print("[Client] Press C to open connection dialog")


func _connect_to_server() -> void:
	"""Connect using localhost control plane."""
	if net_node:
		net_node.control_plane_url = "http://%s:%d" % [server_host, server_port]
		print("[Client] Logging in to %s..." % net_node.control_plane_url)
		net_node.login("")


func _connect_to_production() -> void:
	"""Connect to the production server - used in release builds."""
	if net_node:
		net_node.control_plane_url = PRODUCTION_URL.replace("wss://", "https://").replace("ws://", "http://")
		print("[Client] Logging in to production...")
		net_node.login("")


func _is_release_build() -> bool:
	"""Check if this is a release/exported build (not running in editor)."""
	# OS.has_feature("standalone") is true for exported builds
	# OS.has_feature("editor") is true when running in the Godot editor
	return OS.has_feature("standalone") and not OS.has_feature("editor")


func _show_connection_dialog() -> void:
	"""Show the connection dialog for server selection."""
	if connection_dialog:
		connection_dialog.show_dialog()
	else:
		# Fallback to direct localhost connection if no dialog
		print("[Client] No connection dialog found, using localhost")
		_connect_to_server()


func _show_world_selection_dialog() -> void:
	"""Show the world selection dialog."""
	if world_selection_dialog:
		world_selection_dialog.show_dialog()
	else:
		print("[Client] No world selection dialog found")


func _show_model_selection_dialog() -> void:
	"""Show the model selection dialog for spell creation."""
	if model_selection_dialog:
		_release_mouse()
		model_selection_dialog.show_dialog()
	else:
		print("[Client] No model selection dialog found")


func _on_model_selected(model_id: String) -> void:
	print("[Client] Model loaded for spell creation: ", model_id)
	if spell_creation_screen:
		_release_mouse()
		spell_creation_screen.show_screen(model_id)
	else:
		print("[Client] No spell creation screen found")


func _on_connection_url_requested(url: String) -> void:
	"""Handle connection request from dialog."""
	if net_node:
		# Convert WebSocket URL to HTTP for control plane
		var http_url := url.replace("ws://", "http://").replace("wss://", "https://")
		net_node.control_plane_url = http_url
		print("[Client] Logging in to: ", http_url)
		net_node.login("")


func _on_connected_to_control_plane() -> void:
	print("[Client] Connected to control plane!")


func _on_authenticated(_session_token: String, client_id: String) -> void:
	print("[Client] Authenticated as: ", client_id)
	
	# Show world selection dialog
	call_deferred("_show_world_selection_dialog")


func _on_connected() -> void:
	print("[Client] Connected to game server!")
	
	# Notify connection dialog of success
	if connection_dialog:
		connection_dialog.show_success("Connected!", true)


func _on_disconnected() -> void:
	print("[Client] Disconnected from backend.")


func _on_connection_failed(reason: String = "") -> void:
	var message := reason
	if message.is_empty():
		message = "Connection failed. Is the server running?"
	
	print("[Client] Failed to connect to backend: ", message)
	
	# Notify dialog of failure
	if connection_dialog:
		connection_dialog.show_error(message)


func _on_world_selected(world_id: String) -> void:
	print("[Client] World selected: ", world_id)


func _on_world_joined(world_id: String, world: Dictionary) -> void:
	var world_name: String = world.get("name", "Unknown")
	print("[Client] Joined world: %s (%s)" % [world_name, world_id])
	print("[Client] Press 5/6 to build demo spells, 7/8 to publish, 3/4 to cast")


func _on_world_left(world_id: String) -> void:
	print("[Client] Left world: ", world_id)
	# Show world selection dialog again
	call_deferred("_show_world_selection_dialog")


func _on_sync_complete() -> void:
	if world_node:
		print("[Client] World sync complete! Ops: ", world_node.get_op_count())


func _on_spell_rejected(error: String) -> void:
	print("[Client] Spell rejected: ", error)


func _on_job_progress(job_id: String, stage: String, pct: int, message: String, extras: Dictionary) -> void:
	print("[Client] Job %s: %s %d%% - %s" % [job_id.substr(0, 12), stage, pct, message])
	
	# Track completed revisions
	if extras.has("revision_id"):
		var manifest = extras.get("manifest", {})
		var spell_id = manifest.get("spell_id", "")
		if spell_id:
			_latest_revisions[spell_id] = extras["revision_id"]
			print("[Client] New revision ready: %s/%s" % [spell_id, extras["revision_id"]])


func _on_build_started(job_id: String, spell_id: String) -> void:
	print("[Client] Build started: ", job_id, " for ", spell_id)


func _on_spell_active_update(spell_id: String, revision_id: String, channel: String, _manifest: Dictionary) -> void:
	print("[Client] Spell %s updated on %s: %s" % [spell_id, channel, revision_id])


func _on_spell_error(message: String) -> void:
	print("[Client] Spell error: ", message)


func _on_spell_cast_complete(spell_id: String, _revision_id: String) -> void:
	print("[Client] Spell cast complete: ", spell_id)


func _on_spell_cast_failed(spell_id: String, error: String) -> void:
	print("[Client] Spell cast failed: ", spell_id, " - ", error)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			_dragging_left = mouse_event.pressed
			_last_mouse_pos = mouse_event.position
		elif mouse_event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging_right = mouse_event.pressed
			_last_mouse_pos = mouse_event.position
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_camera(-1.0)
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_camera(1.0)
	
	if event is InputEventMouseMotion and camera != null:
		var motion := event as InputEventMouseMotion
		var delta := motion.position - _last_mouse_pos
		_last_mouse_pos = motion.position
		if _dragging_right:
			_target_camera_rot.x -= delta.x * mouse_sensitivity
			_target_camera_rot.y -= delta.y * mouse_sensitivity
			_target_camera_rot.y = clamp(_target_camera_rot.y, -PI/2 + 0.1, PI/2 - 0.1)
		elif _dragging_left:
			var right := camera.global_transform.basis.x
			var up := camera.global_transform.basis.y
			_target_camera_pos += (-right * delta.x + up * delta.y) * drag_move_speed


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_C, KEY_ENTER:
				if net_node and net_node.is_connected_to_server():
					# Already connected - show world selection
					_show_world_selection_dialog()
				else:
					# Not connected - show connection dialog
					_show_connection_dialog()
			KEY_1:
				_cast_create_land()
			KEY_2:
				_cast_dig()
			KEY_3:
				_cast_spell_package("demo_spark")
			KEY_4:
				_cast_spell_package("demo_spawn")
			KEY_5:
				_build_spell("demo_spark")
			KEY_6:
				_build_spell("demo_spawn")
			KEY_7:
				_publish_spell("demo_spark")
			KEY_8:
				_publish_spell("demo_spawn")
			KEY_S:
				if spell_creation_screen and spell_creation_screen.visible:
					return
				if model_selection_dialog and model_selection_dialog.visible:
					return
				_show_model_selection_dialog()
			KEY_ESCAPE:
				_release_mouse()
			KEY_R:
				_reset_camera()


func _process(delta: float) -> void:
	_handle_camera_movement(delta)
	_apply_camera_smoothing(delta)


func _handle_camera_movement(delta: float) -> void:
	if camera == null:
		return
	
	var input_dir := Vector3.ZERO
	
	if Input.is_key_pressed(KEY_W):
		input_dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		input_dir.z += 1
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_SPACE):
		input_dir.y += 1
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_CTRL):
		input_dir.y -= 1
	
	if input_dir.length_squared() > 0:
		input_dir = input_dir.normalized()
		
		var speed := move_speed
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= fast_move_multiplier
		
		var cam_basis := camera.global_transform.basis
		var forward := -cam_basis.z
		var right := cam_basis.x
		
		forward.y = 0
		forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
		right.y = 0
		right = right.normalized() if right.length() > 0.01 else Vector3.RIGHT
		
		var move_dir := (forward * -input_dir.z + right * input_dir.x + Vector3.UP * input_dir.y).normalized()
		_target_camera_pos += move_dir * speed * delta

func _apply_camera_smoothing(delta: float) -> void:
	if camera == null:
		return
	_camera_rotation = _camera_rotation.lerp(_target_camera_rot, 1.0 - exp(-rotate_smoothness * delta))
	_update_camera_rotation()
	var pos_lerp := 1.0 - exp(-move_smoothness * delta)
	camera.global_position = camera.global_position.lerp(_target_camera_pos, pos_lerp)


func _update_camera_rotation() -> void:
	if camera == null:
		return
	camera.rotation = Vector3(_camera_rotation.y, _camera_rotation.x, 0)


func _toggle_mouse_capture() -> void:
	if _mouse_captured:
		_release_mouse()
	else:
		_capture_mouse()


func _capture_mouse() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_mouse_captured = true


func _release_mouse() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_mouse_captured = false

func _reset_camera() -> void:
	if camera == null:
		return
	camera.global_transform = _default_camera_transform
	var euler := camera.global_transform.basis.get_euler()
	_camera_rotation = Vector2(euler.y, euler.x)
	_target_camera_rot = _camera_rotation
	_target_camera_pos = camera.global_position

func _zoom_camera(direction: float) -> void:
	if camera == null:
		return
	var forward := -camera.global_transform.basis.z
	_target_camera_pos += forward * scroll_zoom_speed * direction


func _get_cast_target() -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var viewport := get_viewport()
	var mouse_pos := viewport.get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos).normalized()
	
	var world := camera.get_world_3d()
	if world == null:
		return ray_origin + ray_dir * cast_distance
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin,
		ray_origin + ray_dir * cast_distance
	)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	
	var hit: Dictionary = space.intersect_ray(query)
	if hit.has("position"):
		return hit["position"]
	
	return ray_origin + ray_dir * cast_distance


# ============================================================================
# Legacy Voxel Spells (1, 2)
# ============================================================================

func _cast_create_land() -> void:
	if world_node == null:
		return
	
	if net_node == null or not net_node.is_connected_to_server():
		print("[Client] Not connected. Press C to connect.")
		return
	
	if not net_node.is_in_world():
		print("[Client] Not in a world. Press C to select a world.")
		return
	
	var target := _get_cast_target()
	
	var spell := {
		"type": "create_land",
		"center": target,
		"radius": default_brush_radius,
		"material_id": 1
	}
	
	print("[Client] Casting create_land at ", target)
	world_node.request_spell(spell)


func _cast_dig() -> void:
	if world_node == null:
		return
	
	if net_node == null or not net_node.is_connected_to_server():
		print("[Client] Not connected. Press C to connect.")
		return
	
	if not net_node.is_in_world():
		print("[Client] Not in a world. Press C to select a world.")
		return
	
	var target := _get_cast_target()
	
	var spell := {
		"type": "dig",
		"center": target,
		"radius": default_brush_radius * 0.75
	}
	
	print("[Client] Casting dig at ", target)
	world_node.request_spell(spell)


# ============================================================================
# New Spell System (3-8)
# ============================================================================

func _cast_spell_package(spell_id: String) -> void:
	"""Cast a spell using the new package system."""
	if spell_cast == null:
		print("[Client] SpellCastController not available")
		return
	
	if net_node == null or not net_node.is_connected_to_server():
		print("[Client] Not connected. Press C to connect.")
		return
	
	if not net_node.is_in_world():
		print("[Client] Not in a world. Press C to select a world.")
		return
	
	var target := _get_cast_target()
	print("[Client] Casting spell package: ", spell_id, " at ", target)
	
	spell_cast.cast_spell(spell_id, target, {})


func _build_spell(spell_id: String) -> void:
	"""Request the server to build a new revision of a spell."""
	if spell_net == null:
		print("[Client] SpellNet not available")
		return
	
	if net_node == null or not net_node.is_connected_to_server():
		print("[Client] Not connected. Press C to connect.")
		return
	
	print("[Client] Starting build for: ", spell_id)
	
	# Use custom code for demo spells
	var code := _get_demo_spell_code(spell_id)
	
	spell_net.start_build(spell_id, {
		"code": code,
		"metadata": {
			"name": spell_id.replace("_", " ").capitalize(),
			"description": "Demo spell: " + spell_id
		}
	})


func _publish_spell(spell_id: String) -> void:
	"""Publish the latest revision of a spell to beta channel."""
	if spell_net == null:
		print("[Client] SpellNet not available")
		return
	
	if net_node == null or not net_node.is_connected_to_server():
		print("[Client] Not connected. Press C to connect.")
		return
	
	var revision_id: String = _latest_revisions.get(spell_id, "")
	
	if revision_id.is_empty():
		print("[Client] No revision to publish for: ", spell_id)
		print("[Client] Build one first with key 5 or 6")
		return
	
	print("[Client] Publishing %s revision %s to beta" % [spell_id, revision_id])
	spell_net.publish_revision(spell_id, revision_id, "beta")


func _get_demo_spell_code(spell_id: String) -> String:
	"""Get the demo spell code for a given spell ID."""
	match spell_id:
		"demo_spark":
			return DEMO_SPARK_CODE
		"demo_spawn":
			return DEMO_SPAWN_CODE
		_:
			return ""


# ============================================================================
# Demo Spell Code Templates
# ============================================================================

const DEMO_SPARK_CODE := """extends SpellModule
## Demo Spark - creates a burst of particles at the target location

func get_manifest() -> Dictionary:
	return {
		"spell_id": "demo_spark",
		"name": "Demo Spark",
		"description": "Creates a colorful spark effect"
	}


func on_cast(ctx: SpellContext) -> void:
	print("[demo_spark] Cast at: ", ctx.target_position, " by: ", ctx.caster_id)
	
	if ctx.world:
		# Create multiple particle bursts with random colors
		var colors := [Color.CYAN, Color.MAGENTA, Color.YELLOW, Color.LIME]
		
		for i in range(3):
			var offset := Vector3(
				ctx.randf_range(-1, 1),
				ctx.randf_range(0, 2),
				ctx.randf_range(-1, 1)
			)
			var color: Color = colors[ctx.randi_range(0, colors.size() - 1)]
			
			ctx.world.play_vfx("spark", ctx.target_position + offset, {
				"color": color,
				"amount": 24,
				"speed": 8.0,
				"lifetime": 0.8
			})
	
	print("[demo_spark] Effect complete!")


func on_tick(_ctx: SpellContext, _dt: float) -> void:
	pass


func on_cancel(_ctx: SpellContext) -> void:
	print("[demo_spark] Cancelled")
"""


const DEMO_SPAWN_CODE := """extends SpellModule
## Demo Spawn - spawns a simple 3D object at the target location

func get_manifest() -> Dictionary:
	return {
		"spell_id": "demo_spawn",
		"name": "Demo Spawn",
		"description": "Spawns a floating cube at the target"
	}


func on_cast(ctx: SpellContext) -> void:
	print("[demo_spawn] Cast at: ", ctx.target_position, " by: ", ctx.caster_id)
	
	if ctx.world:
		# Create a simple cube mesh
		var mesh := BoxMesh.new()
		mesh.size = Vector3(1.5, 1.5, 1.5)
		
		# Create a material with a random color
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(
			ctx.randf_range(0.3, 1.0),
			ctx.randf_range(0.3, 1.0),
			ctx.randf_range(0.3, 1.0)
		)
		mat.metallic = 0.3
		mat.roughness = 0.7
		
		# Spawn the mesh
		var transform := Transform3D.IDENTITY
		transform.origin = ctx.target_position
		
		var cube := ctx.world.spawn_simple_mesh(mesh, transform, mat)
		
		if cube:
			# Add some rotation animation
			var tween := cube.create_tween()
			tween.set_loops()
			tween.tween_property(cube, "rotation:y", TAU, 4.0)
			
			# Auto-destroy after 10 seconds
			var timer := Timer.new()
			timer.wait_time = 10.0
			timer.one_shot = true
			timer.timeout.connect(func(): 
				if is_instance_valid(cube):
					cube.queue_free()
			)
			cube.add_child(timer)
			timer.start()
			
			print("[demo_spawn] Cube spawned!")
	
	# Also play a small effect
	if ctx.world:
		ctx.world.play_vfx("spawn_flash", ctx.target_position, {
			"color": Color.WHITE,
			"amount": 8,
			"speed": 3.0
		})


func on_tick(_ctx: SpellContext, _dt: float) -> void:
	pass


func on_cancel(_ctx: SpellContext) -> void:
	print("[demo_spawn] Cancelled")
"""
