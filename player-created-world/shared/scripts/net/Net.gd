extends Node

## WebSocket client for connecting to the Python backend.
## This is a client-only implementation - no server hosting capability.
## Supports multi-world architecture where a server can host multiple worlds.

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 5000
const LOCALHOST_URL := "ws://127.0.0.1:5000"
const PRODUCTION_URL := "wss://ugc-world-backend.fly.dev"

signal connected_to_server
signal disconnected_from_server
signal connection_failed
signal message_received(data: Dictionary)

# World management signals
signal world_list_received(worlds: Array)
signal world_created(world: Dictionary)
signal world_joined(world_id: String, world: Dictionary)
signal world_left(world_id: String)
signal world_list_updated(worlds: Array)

var _socket: WebSocketPeer = null
var _connected := false
var _connecting := false

## Server URL
var server_url: String = ""

## Current world ID (empty if not in a world)
var current_world_id: String = ""

## Current world info
var current_world: Dictionary = {}


func _ready() -> void:
	set_process(false)


func _process(_delta: float) -> void:
	if _socket == null:
		return
	
	_socket.poll()
	
	var state := _socket.get_ready_state()
	
	match state:
		WebSocketPeer.STATE_OPEN:
			if _connecting:
				_connecting = false
				_connected = true
				print("[Net] Connected to server!")
				connected_to_server.emit()
			
			# Process incoming messages
			while _socket.get_available_packet_count() > 0:
				var packet := _socket.get_packet()
				var text := packet.get_string_from_utf8()
				_handle_message(text)
		
		WebSocketPeer.STATE_CLOSING:
			pass  # Wait for close
		
		WebSocketPeer.STATE_CLOSED:
			var code := _socket.get_close_code()
			var reason := _socket.get_close_reason()
			print("[Net] Connection closed. Code: ", code, " Reason: ", reason)
			_socket = null
			set_process(false)
			
			if _connected:
				_connected = false
				disconnected_from_server.emit()
			elif _connecting:
				_connecting = false
				connection_failed.emit()
		
		WebSocketPeer.STATE_CONNECTING:
			pass  # Still connecting


func connect_to_server(host: String = DEFAULT_HOST, port: int = DEFAULT_PORT) -> void:
	"""Connect to the Python backend server using host and port."""
	var url := "ws://%s:%d" % [host, port]
	connect_to_url(url)


func connect_to_url(url: String) -> void:
	"""Connect to a server using a full URL (ws:// or wss://)."""
	if _connected or _connecting:
		print("[Net] Already connected or connecting")
		return
	
	server_url = url
	print("[Net] Connecting to ", server_url)
	
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(server_url)
	
	if err != OK:
		push_error("[Net] Failed to initiate connection: %s" % err)
		_socket = null
		connection_failed.emit()
		return
	
	_connecting = true
	set_process(true)


func disconnect_from_server() -> void:
	"""Disconnect from the server."""
	if _socket != null:
		_socket.close()
		_socket = null
	
	_connected = false
	_connecting = false
	current_world_id = ""
	current_world = {}
	set_process(false)


func send_message(data: Dictionary) -> void:
	"""Send a JSON message to the server."""
	if not _connected or _socket == null:
		push_warning("[Net] Cannot send - not connected")
		return
	
	var json_str := JSON.stringify(data)
	_socket.send_text(json_str)


func _handle_message(text: String) -> void:
	"""Handle incoming message from server."""
	var json := JSON.new()
	var err := json.parse(text)
	
	if err != OK:
		push_warning("[Net] Invalid JSON received: ", text.substr(0, 100))
		return
	
	var data: Dictionary = json.data
	
	# Handle world management messages internally
	var msg_type: String = data.get("type", "")
	match msg_type:
		"world.list_result":
			var worlds: Array = data.get("worlds", [])
			world_list_received.emit(worlds)
		"world.created":
			var world: Dictionary = data.get("world", {})
			world_created.emit(world)
		"world.joined":
			current_world_id = data.get("world_id", "")
			current_world = data.get("world", {})
			print("[Net] Joined world: ", current_world_id)
			world_joined.emit(current_world_id, current_world)
		"world.left":
			var left_id: String = data.get("left_world_id", "")
			current_world_id = ""
			current_world = {}
			print("[Net] Left world: ", left_id)
			world_left.emit(left_id)
		"world.list_updated":
			var worlds: Array = data.get("worlds", [])
			world_list_updated.emit(worlds)
	
	# Always emit for other handlers
	message_received.emit(data)


func is_connected_to_server() -> bool:
	return _connected


func is_connecting() -> bool:
	return _connecting


func is_in_world() -> bool:
	return not current_world_id.is_empty()


func get_current_world_id() -> String:
	return current_world_id


func get_current_world() -> Dictionary:
	return current_world


# ============================================================================
# World Management
# ============================================================================

func request_world_list() -> void:
	"""Request list of available worlds from server."""
	send_message({"type": "world.list"})


func create_world(world_name: String, description: String = "") -> void:
	"""Request creation of a new world."""
	send_message({
		"type": "world.create",
		"name": world_name,
		"description": description
	})


func join_world(world_id: String) -> void:
	"""Request to join a specific world."""
	send_message({
		"type": "world.join",
		"world_id": world_id
	})


func leave_world() -> void:
	"""Request to leave current world."""
	send_message({"type": "world.leave"})


func ping() -> void:
	"""Send a ping to the server."""
	send_message({"type": "ping"})
