extends Node

## Client controller for terraforming demo.
## Connects to the Python backend server.
##
## Controls:
## - C or Enter: Connect to server
## - 1: Cast create_land spell (add_sphere)
## - 2: Cast dig spell (subtract_sphere)
## - WASD: Move camera
## - Right-click: Toggle mouse look
## - Shift: Move faster

## Camera settings
@export var move_speed: float = 20.0
@export var fast_move_multiplier: float = 3.0
@export var mouse_sensitivity: float = 0.003

## Spell settings
@export var default_brush_radius: float = 8.0
@export var cast_distance: float = 30.0

## Server settings
@export var server_host: String = "127.0.0.1"
@export var server_port: int = 5000
@export var auto_connect: bool = true

## References
var camera: Camera3D = null
var net_node: Node = null
var world_node: Node = null

## State
var _mouse_captured: bool = false
var _camera_rotation: Vector2 = Vector2.ZERO


func _ready() -> void:
	# Get autoload references
	net_node = get_node_or_null("/root/Net")
	world_node = get_node_or_null("/root/World")
	
	# Find camera in scene
	camera = get_viewport().get_camera_3d()
	if camera:
		var euler = camera.global_transform.basis.get_euler()
		_camera_rotation = Vector2(euler.y, euler.x)
	
	# Connect to network signals
	if net_node:
		net_node.connected_to_server.connect(_on_connected)
		net_node.disconnected_from_server.connect(_on_disconnected)
		net_node.connection_failed.connect(_on_connection_failed)
	
	# Connect to world signals
	if world_node:
		world_node.sync_complete.connect(_on_sync_complete)
		world_node.spell_rejected.connect(_on_spell_rejected)
	
	# Auto-connect to server
	if auto_connect:
		call_deferred("_connect_to_server")


func _connect_to_server() -> void:
	if net_node:
		print("[Client] Connecting to backend at %s:%d..." % [server_host, server_port])
		net_node.connect_to_server(server_host, server_port)


func _on_connected() -> void:
	print("[Client] Connected to backend!")


func _on_disconnected() -> void:
	print("[Client] Disconnected from backend.")


func _on_connection_failed() -> void:
	print("[Client] Failed to connect to backend. Is the server running?")
	print("[Client] Start backend with: cd ugc_backend && python app.py")


func _on_sync_complete() -> void:
	if world_node:
		print("[Client] World sync complete! Ops: ", world_node.get_op_count())


func _on_spell_rejected(error: String) -> void:
	print("[Client] Spell rejected: ", error)


func _input(event: InputEvent) -> void:
	# Mouse look when captured
	if event is InputEventMouseMotion and _mouse_captured:
		_camera_rotation.x -= event.relative.x * mouse_sensitivity
		_camera_rotation.y -= event.relative.y * mouse_sensitivity
		_camera_rotation.y = clamp(_camera_rotation.y, -PI/2 + 0.1, PI/2 - 0.1)
		_update_camera_rotation()
	
	# Toggle mouse capture
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_toggle_mouse_capture()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_C, KEY_ENTER:
				_connect_to_server()
			KEY_1:
				_cast_create_land()
			KEY_2:
				_cast_dig()
			KEY_ESCAPE:
				_release_mouse()


func _process(delta: float) -> void:
	_handle_camera_movement(delta)


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
		camera.global_position += move_dir * speed * delta


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


func _get_cast_target() -> Vector3:
	if camera == null:
		return Vector3.ZERO
	
	var cam_pos := camera.global_position
	var cam_forward := -camera.global_transform.basis.z
	
	return cam_pos + cam_forward * cast_distance


func _cast_create_land() -> void:
	if world_node == null:
		return
	
	if net_node == null or not net_node.is_connected_to_server():
		print("[Client] Not connected. Press C to connect.")
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
	
	var target := _get_cast_target()
	
	var spell := {
		"type": "dig",
		"center": target,
		"radius": default_brush_radius * 0.75
	}
	
	print("[Client] Casting dig at ", target)
	world_node.request_spell(spell)
