extends Node

## Client-side world state manager.
## Receives ops from the Python backend and applies them locally.
## Sends spell requests to the backend for validation and broadcasting.
## 
## Supports multi-world architecture where clients join specific worlds.

signal op_applied(op: Dictionary)
signal sync_complete
signal spell_rejected(error: String)
signal world_cleared

## Local operation log (received from server)
var op_log: Array[Dictionary] = []

## Track if we've received initial sync
var _synced := false


func _ready() -> void:
	# Connect to Net signals
	var net_node = get_node_or_null("/root/Net")
	if net_node:
		net_node.message_received.connect(_on_message_received)
		net_node.connected_to_server.connect(_on_connected)
		net_node.disconnected_from_server.connect(_on_disconnected)
		net_node.world_joined.connect(_on_world_joined)
		net_node.world_left.connect(_on_world_left)


func _on_connected() -> void:
	print("[World] Connected to server. Select a world to join...")
	_synced = false


func _on_disconnected() -> void:
	print("[World] Disconnected from server.")
	_synced = false
	op_log.clear()


func _on_world_joined(world_id: String, world: Dictionary) -> void:
	print("[World] Joined world: ", world_id, " - ", world.get("name", "Unknown"))
	# Clear previous ops - new sync will come
	op_log.clear()
	_synced = false


func _on_world_left(world_id: String) -> void:
	print("[World] Left world: ", world_id)
	op_log.clear()
	_synced = false


func _on_message_received(data: Dictionary) -> void:
	"""Handle messages from the server."""
	var msg_type: String = data.get("type", "")
	
	match msg_type:
		"sync_ops":
			_handle_sync_ops(data)
		"sync_complete":
			_handle_sync_complete(data)
		"apply_op":
			_handle_apply_op(data)
		"spell_rejected":
			_handle_spell_rejected(data)
		"world_cleared":
			_handle_world_cleared(data)
		"pong":
			var world_id: String = data.get("world_id", "")
			print("[World] Pong received. Clients: %d, World: %s" % [data.get("clients", 0), world_id])
		_:
			pass  # Ignore unknown types - other handlers may process them


func _handle_sync_ops(data: Dictionary) -> void:
	"""Handle initial sync from server."""
	var ops: Array = data.get("ops", [])
	print("[World] Receiving ", ops.size(), " ops for sync...")
	
	for op_data in ops:
		var op: Dictionary = op_data
		op_log.append(op)
		_emit_op_applied(op)
	
	_synced = true
	sync_complete.emit()
	print("[World] Sync complete. Total ops: ", op_log.size())


func _handle_sync_complete(data: Dictionary) -> void:
	"""Handle sync complete (empty world)."""
	_synced = true
	sync_complete.emit()
	print("[World] Sync complete. World is empty.")


func _handle_apply_op(data: Dictionary) -> void:
	"""Handle an operation broadcast from server."""
	var op: Dictionary = data.get("op", {})
	if op.is_empty():
		return
	
	op_log.append(op)
	_emit_op_applied(op)


func _handle_spell_rejected(data: Dictionary) -> void:
	"""Handle spell rejection from server."""
	var error: String = data.get("error", "Unknown error")
	print("[World] Spell rejected: ", error)
	spell_rejected.emit(error)


func _handle_world_cleared(data: Dictionary) -> void:
	"""Handle world clear notification."""
	var world_id: String = data.get("world_id", "")
	op_log.clear()
	print("[World] World %s was cleared by server." % world_id)
	world_cleared.emit()


func _emit_op_applied(op: Dictionary) -> void:
	"""Convert server op format to local format and emit."""
	# Convert center from {x, y, z} dict to Vector3
	var center_data = op.get("center", {})
	if center_data is Dictionary:
		op = op.duplicate()
		op["center"] = Vector3(
			float(center_data.get("x", 0)),
			float(center_data.get("y", 0)),
			float(center_data.get("z", 0))
		)
	
	op_applied.emit(op)


func request_spell(spell: Dictionary) -> void:
	"""Send a spell request to the server."""
	var net_node = get_node_or_null("/root/Net")
	if net_node == null or not net_node.is_connected_to_server():
		print("[World] Cannot cast spell - not connected to server")
		return
	
	if not net_node.is_in_world():
		print("[World] Cannot cast spell - not in a world")
		return
	
	# Convert Vector3 to dict for JSON serialization
	var spell_copy := spell.duplicate()
	var center = spell_copy.get("center")
	if center is Vector3:
		spell_copy["center"] = {
			"x": center.x,
			"y": center.y,
			"z": center.z
		}
	
	net_node.send_message({
		"type": "request_spell",
		"spell": spell_copy
	})


## Utility functions

func get_op_count() -> int:
	return op_log.size()


func is_synced() -> bool:
	return _synced


func clear_local() -> void:
	"""Clear local op log (doesn't affect server)."""
	op_log.clear()
