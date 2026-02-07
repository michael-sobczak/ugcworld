extends Node

## Network client for UGC World.
## Handles both control plane (HTTP) and game server (WebSocket) connections.
## 
## Flow:
## 1. login() -> authenticate with control plane
## 2. join_world() -> get game server address from control plane
## 3. Connect to game server WebSocket
## 4. Send inputs, receive snapshots

signal connected_to_control_plane
signal authenticated(session_token: String, client_id: String)
signal connected_to_game_server
signal disconnected_from_server
signal connection_failed(reason: String)
signal message_received(data: Dictionary)

# World management signals
signal world_list_received(worlds: Array)
signal world_created(world: Dictionary)
signal world_joined(world_id: String, world: Dictionary)
signal world_left(world_id: String)

# Spell signals
signal job_progress(job_id: String, stage: String, pct: int, message: String, extras: Dictionary)
signal spell_active_update(spell_id: String, revision_id: String, channel: String, manifest: Dictionary)

const DEFAULT_CONTROL_PLANE := "http://127.0.0.1:5000"
const PRODUCTION_CONTROL_PLANE := "https://ugc-world-backend.fly.dev"

## Control plane URL (for auth, matchmaking)
var control_plane_url: String = DEFAULT_CONTROL_PLANE

## Session info
var session_token: String = ""
var client_id: String = ""
var username: String = ""

## Game server connection
var game_server_address: String = ""
var world_id: String = ""
var local_entity_id: int = 0

## Connection state
enum State { DISCONNECTED, AUTHENTICATING, CONNECTING_GAME, HANDSHAKING, IN_LOBBY, IN_WORLD }
var state: State = State.DISCONNECTED

## WebSocket for control plane (plain WebSocket for real-time updates)
var _cp_ws: WebSocketPeer = null

## WebSocket for game server (plain WebSocket for custom protocol)
var _gs_ws: WebSocketPeer = null

## HTTP client for control plane
var _http: HTTPRequest = null
var _pending_request: String = ""
var _last_gs_state: int = -1  # Track connection state for debug output


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_http_completed)
	
	# Use production in release builds
	if _is_release_build():
		control_plane_url = PRODUCTION_CONTROL_PLANE


func _process(_delta: float) -> void:
	# Poll game server WebSocket
	if _gs_ws == null:
		return
	
	_gs_ws.poll()
	var gs_state := _gs_ws.get_ready_state()
	
	# Debug output (only when state changes)
	if gs_state != _last_gs_state:
		var state_names: Array[String] = ["CONNECTING", "OPEN", "CLOSING", "CLOSED"]
		var old_name: String = state_names[_last_gs_state] if _last_gs_state >= 0 and _last_gs_state < 4 else str(_last_gs_state)
		var new_name: String = state_names[gs_state] if gs_state >= 0 and gs_state < 4 else str(gs_state)
		print("[Net] Game server WebSocket state: %s -> %s" % [old_name, new_name])
		_last_gs_state = gs_state
	
	if gs_state == WebSocketPeer.STATE_OPEN:
		# Handle connection established
		if state == State.CONNECTING_GAME:
			_on_game_server_connected()
		
		# Receive and process messages
		if state == State.HANDSHAKING or state == State.IN_WORLD:
			while _gs_ws.get_available_packet_count() > 0:
				var packet := _gs_ws.get_packet()
				var text := packet.get_string_from_utf8()
				# Only log non-snapshot messages
				if not text.contains('"type":101'):
					print("[Net] Received from game server: %s" % text.substr(0, 200))
				_handle_ws_message(text)
	
	elif gs_state == WebSocketPeer.STATE_CLOSED:
		print("[Net] Game server disconnected (code: %d)" % _gs_ws.get_close_code())
		_gs_ws = null
		
		if state == State.IN_WORLD or state == State.CONNECTING_GAME or state == State.HANDSHAKING:
			state = State.IN_LOBBY if not session_token.is_empty() else State.DISCONNECTED
		disconnected_from_server.emit()


func _is_release_build() -> bool:
	return OS.has_feature("standalone") and not OS.has_feature("editor")


# =============================================================================
# Public API
# =============================================================================

func login(player_username: String = "") -> void:
	"""Login to control plane."""
	if state != State.DISCONNECTED:
		push_warning("[Net] Already connected")
		return
	
	state = State.AUTHENTICATING
	username = player_username
	
	_pending_request = "login"
	var body := JSON.stringify({"username": player_username})
	var headers := ["Content-Type: application/json"]
	
	print("[Net] Logging in to %s..." % control_plane_url)
	_http.request(control_plane_url + "/login", headers, HTTPClient.METHOD_POST, body)


func join_world(target_world_id: String = "", world_name: String = "") -> void:
	"""Request to join a world."""
	if session_token.is_empty():
		push_error("[Net] Not authenticated")
		return
	
	_pending_request = "join"
	var body := JSON.stringify({
		"world_id": target_world_id,
		"name": world_name if world_name else "New World",
	})
	var headers := [
		"Content-Type: application/json",
		"Authorization: Bearer " + session_token,
	]
	
	print("[Net] Joining world...")
	_http.request(control_plane_url + "/join", headers, HTTPClient.METHOD_POST, body)


func request_world_list() -> void:
	"""Request list of available worlds."""
	if _cp_ws and _cp_ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_to_control_plane({"type": "world.list"})
	else:
		if _http and _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
			print("[Net] Skipping world list request - HTTPRequest busy")
			return
		# Use HTTP fallback
		_pending_request = "worlds"
		var headers := ["Authorization: Bearer " + session_token] if session_token else []
		_http.request(control_plane_url + "/worlds", headers, HTTPClient.METHOD_GET)


func create_world(world_name: String, description: String = "") -> void:
	"""Create a new world."""
	if _cp_ws and _cp_ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_to_control_plane({"type": "world.create", "name": world_name, "description": description})


func leave_world() -> void:
	"""Leave current world."""
	if _gs_ws:
		_gs_ws.close()
		_gs_ws = null
	
	world_id = ""
	local_entity_id = 0
	state = State.IN_LOBBY
	world_left.emit(world_id)


func disconnect_from_server() -> void:
	"""Disconnect completely."""
	if _gs_ws:
		_gs_ws.close()
		_gs_ws = null
	
	if _cp_ws:
		_cp_ws.close()
		_cp_ws = null
	
	session_token = ""
	client_id = ""
	world_id = ""
	local_entity_id = 0
	state = State.DISCONNECTED


func send_message(data: Dictionary) -> void:
	"""Send message to game server."""
	_send_to_game_server(data)


func is_connected_to_server() -> bool:
	return state == State.IN_LOBBY or state == State.IN_WORLD


func is_in_world() -> bool:
	return state == State.IN_WORLD and not world_id.is_empty()


func get_current_world_id() -> String:
	return world_id


func ping() -> void:
	"""Send ping."""
	_send_to_game_server({"type": 5})  # Protocol.ClientMsg.PING


# =============================================================================
# Control Plane WebSocket (for spell updates, etc.)
# =============================================================================

func connect_to_control_plane_ws() -> void:
	"""Connect WebSocket to control plane for real-time updates."""
	var ws_url := control_plane_url.replace("http://", "ws://").replace("https://", "wss://")
	
	if _cp_ws != null:
		_cp_ws.close()
	
	_cp_ws = WebSocketPeer.new()
	var err := _cp_ws.connect_to_url(ws_url)
	
	if err != OK:
		push_error("[Net] Failed to connect to control plane WS")
		return
	
	print("[Net] Connecting to control plane WebSocket: %s" % ws_url)


# =============================================================================
# Game Server Connection
# =============================================================================

func _connect_to_game_server(address: String) -> void:
	"""Connect to game server using plain WebSocketPeer."""
	print("[Net] _connect_to_game_server called with address: %s" % address)
	
	if _gs_ws != null:
		print("[Net] Closing existing game server connection...")
		_gs_ws.close()
		_gs_ws = null
	
	state = State.CONNECTING_GAME
	game_server_address = address
	_last_gs_state = -1  # Reset connection state tracking
	
	_gs_ws = WebSocketPeer.new()
	var err := _gs_ws.connect_to_url(address)
	
	if err != OK:
		push_error("[Net] Failed to connect to game server: %d" % err)
		state = State.IN_LOBBY
		_gs_ws = null
		connection_failed.emit("Failed to connect: %d" % err)
		return
	
	print("[Net] Connecting to game server at: %s" % address)


func _on_game_server_connected() -> void:
	"""Called when connected to game server - send handshake."""
	# Prevent multiple calls
	if state == State.HANDSHAKING:
		return
	
	state = State.HANDSHAKING  # New state: connected but waiting for handshake response
	print("[Net] Game server connected! Sending handshake...")
	
	# Send handshake with session credentials (type 1 = HANDSHAKE from Protocol)
	var handshake := {
		"type": 1,  # Protocol.ClientMsg.HANDSHAKE
		"protocol_version": 1,
		"session_token": session_token,
		"client_id": client_id,
	}
	print("[Net] Handshake data: %s" % JSON.stringify(handshake))
	_send_to_game_server(handshake)
	print("[Net] Handshake sent, waiting for response...")


# =============================================================================
# Internal
# =============================================================================

func _send_to_game_server(data: Dictionary) -> void:
	"""Send message to game server via WebSocketPeer."""
	if _gs_ws == null:
		print("[Net] Cannot send - _gs_ws is null")
		return
	
	if _gs_ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		print("[Net] Cannot send - WebSocket not open (state: %d)" % _gs_ws.get_ready_state())
		return
	
	var json_str := JSON.stringify(data)
	print("[Net] Sending to game server: %s" % json_str.substr(0, 200))
	
	var err := _gs_ws.send_text(json_str)
	if err != OK:
		print("[Net] Failed to send: %d" % err)
	else:
		print("[Net] Sent successfully")


func _send_to_control_plane(data: Dictionary) -> void:
	"""Send message to control plane WebSocket."""
	if _cp_ws == null or _cp_ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	
	var json_str := JSON.stringify(data)
	_cp_ws.send_text(json_str)


func _handle_ws_message(text: String) -> void:
	"""Handle incoming WebSocket message."""
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_warning("[Net] Invalid JSON: %s" % text.substr(0, 100))
		return
	
	var data: Dictionary = json.data
	var raw_type = data.get("type", "")
	
	# JSON parses numbers as floats - convert to int for matching
	var msg_type: Variant = raw_type
	if raw_type is float:
		msg_type = int(raw_type)
	
	# Handle both string types (control plane) and integer types (game server)
	match msg_type:
		# Game server messages (integer types from Protocol)
		100:  # HANDSHAKE_RESPONSE
			var success: bool = data.get("success", false)
			if success:
				local_entity_id = data.get("assigned_entity_id", 0)
				world_id = data.get("world_id", "")
				state = State.IN_WORLD
				print("[Net] Joined world %s as entity %d" % [world_id, local_entity_id])
				world_joined.emit(world_id, {"world_id": world_id})
				connected_to_game_server.emit()
			else:
				print("[Net] Handshake failed: %s" % data.get("error", ""))
				state = State.IN_LOBBY
		
		101:  # STATE_SNAPSHOT
			pass  # Will be handled by game state manager
		
		109:  # ERROR
			push_warning("[Net] Server error: %s" % data.get("message", ""))
		
		# Control plane messages (string types)
		"connected":
			print("[Net] Control plane WebSocket connected")
		
		"handshake_response":  # Legacy string format
			var success: bool = data.get("success", false)
			if success:
				local_entity_id = data.get("assigned_entity_id", 0)
				world_id = data.get("world_id", "")
				state = State.IN_WORLD
				print("[Net] Joined world %s as entity %d" % [world_id, local_entity_id])
				world_joined.emit(world_id, {"world_id": world_id})
				connected_to_game_server.emit()
			else:
				print("[Net] Handshake failed: %s" % data.get("error", ""))
				state = State.IN_LOBBY
		
		# World management (control plane)
		"world.list_result":
			world_list_received.emit(data.get("worlds", []))
		
		"world.created":
			world_created.emit(data.get("world", {}))
		
		"world.joined":
			world_id = data.get("world_id", "")
			state = State.IN_WORLD
			world_joined.emit(world_id, data.get("world", {}))
		
		"world.left":
			world_left.emit(data.get("world_id", ""))
			world_id = ""
			state = State.IN_LOBBY
		
		# Job progress
		"job.progress":
			job_progress.emit(
				data.get("job_id", ""),
				data.get("stage", ""),
				data.get("pct", 0),
				data.get("message", ""),
				data
			)
		
		# Spell updates
		"spell.active_update":
			spell_active_update.emit(
				data.get("spell_id", ""),
				data.get("revision_id", ""),
				data.get("channel", ""),
				data.get("manifest", {})
			)
		
		"pong":
			pass
		
		"error":
			push_warning("[Net] Server error: %s" % data.get("message", ""))
	
	# Always emit for other handlers
	message_received.emit(data)


func _on_http_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	"""Handle HTTP response."""
	var request_type := _pending_request
	_pending_request = ""
	
	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("[Net] HTTP request failed: %d" % result)
		if state == State.AUTHENTICATING:
			state = State.DISCONNECTED
			connection_failed.emit("HTTP request failed")
		return
	
	var json := JSON.new()
	var parse_err := json.parse(body.get_string_from_utf8())
	if parse_err != OK:
		push_error("[Net] Failed to parse response")
		return
	
	var data: Dictionary = json.data
	
	if response_code >= 400:
		var error_msg: String = data.get("error", "Request failed")
		push_error("[Net] HTTP %d: %s" % [response_code, error_msg])
		if state == State.AUTHENTICATING:
			state = State.DISCONNECTED
			connection_failed.emit(error_msg)
		return
	
	match request_type:
		"login":
			session_token = data.get("session_token", "")
			client_id = data.get("client_id", "")
			username = data.get("username", username)
			
			if session_token.is_empty():
				state = State.DISCONNECTED
				connection_failed.emit("No session token")
				return
			
			state = State.IN_LOBBY
			print("[Net] Authenticated as %s" % client_id)
			authenticated.emit(session_token, client_id)
			connected_to_control_plane.emit()
			
			# Connect to control plane WebSocket for real-time updates
			# connect_to_control_plane_ws()  # Disabled - Flask-SocketIO uses different protocol
			pass
		
		"join":
			game_server_address = data.get("server_address", "")
			world_id = data.get("world_id", "")
			
			if game_server_address.is_empty():
				push_error("[Net] No game server address")
				return
			
			print("[Net] Got game server: %s for world %s" % [game_server_address, world_id])
			_connect_to_game_server(game_server_address)
		
		"worlds":
			world_list_received.emit(data.get("worlds", []))
