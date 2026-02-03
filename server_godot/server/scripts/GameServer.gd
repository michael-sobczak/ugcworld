extends Node
## Authoritative Game Server
## Runs the main simulation loop and manages all connected clients.
## 
## Launch headless: godot --headless --path . --main-scene res://server/scenes/GameServer.tscn

signal client_connected(client_id: int)
signal client_disconnected(client_id: int)
signal client_authenticated(client_id: int, session_token: String)

## Server configuration
@export var listen_port: int = 7777
@export var max_clients: int = 32
@export var control_plane_url: String = "http://127.0.0.1:5000"

## Tick configuration
const TICK_RATE := Protocol.SERVER_TICK_RATE
const TICK_INTERVAL := 1.0 / TICK_RATE
const SNAPSHOT_INTERVAL := Protocol.TICKS_PER_SNAPSHOT

## Current server tick
var server_tick: int = 0

## World ID this server is hosting
var world_id: String = ""

## Connected clients
## client_id -> ClientSession
var _clients: Dictionary = {}

## TCP server for WebSocket connections
var _tcp_server: TCPServer = null
var _ws_peers: Dictionary = {}  # peer_id -> WebSocketPeer
var _peer_to_client: Dictionary = {}  # peer_id -> client_id
var _next_peer_id: int = 1

## Input buffer per client: client_id -> {tick -> InputFrame}
var _input_buffers: Dictionary = {}

## Time tracking
var _tick_accumulator: float = 0.0
var _ticks_since_snapshot: int = 0

## Simulation components (will be instantiated)
var _physics_world: Node3D = null
var _chunk_manager: Node = null
var _npc_manager: Node = null
var _projectile_manager: Node = null

## Entity registry reference
@onready var entity_registry: Node = get_node("/root/EntityRegistry")


func _ready() -> void:
	# Force output to be unbuffered
	print("")
	print("============================================================")
	print("UGC World Authoritative Game Server")
	print("Godot Version: %s" % Engine.get_version_info().string)
	print("============================================================")
	
	# Parse command line arguments
	_parse_arguments()
	
	# Initialize simulation
	_setup_simulation()
	
	# Start network server
	_start_server()
	
	print("[GameServer] Server ready on port %d" % listen_port)
	print("[GameServer] Tick rate: %d Hz, Snapshot rate: %d Hz" % [TICK_RATE, TICK_RATE / SNAPSHOT_INTERVAL])
	print("============================================================")


func _parse_arguments() -> void:
	"""Parse command line arguments."""
	var args := OS.get_cmdline_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--port":
				if i + 1 < args.size():
					listen_port = int(args[i + 1])
					i += 1
			"--world":
				if i + 1 < args.size():
					world_id = args[i + 1]
					i += 1
			"--control-plane":
				if i + 1 < args.size():
					control_plane_url = args[i + 1]
					i += 1
		i += 1
	
	# Generate world ID if not provided
	if world_id.is_empty():
		world_id = "world_%s" % _generate_short_id()
	
	print("[GameServer] Command line args: %s" % str(args))
	print("[GameServer] Port: %d" % listen_port)
	print("[GameServer] World ID: %s" % world_id)
	print("[GameServer] Control Plane: %s" % control_plane_url)


func _generate_short_id() -> String:
	"""Generate a short random ID."""
	var chars := "abcdefghijklmnopqrstuvwxyz0123456789"
	var result := ""
	for i in range(8):
		result += chars[randi() % chars.length()]
	return result


func _setup_simulation() -> void:
	"""Initialize simulation components."""
	# Create physics world container
	_physics_world = Node3D.new()
	_physics_world.name = "PhysicsWorld"
	add_child(_physics_world)
	
	# Add chunk manager for voxel terrain
	var chunk_script := load("res://server/scripts/ChunkManager.gd") as GDScript
	_chunk_manager = chunk_script.new()
	_chunk_manager.name = "ChunkManager"
	add_child(_chunk_manager)
	
	# Add NPC manager
	var npc_script := load("res://server/scripts/NPCManager.gd") as GDScript
	_npc_manager = npc_script.new()
	_npc_manager.name = "NPCManager"
	add_child(_npc_manager)
	
	# Add projectile manager
	var projectile_script := load("res://server/scripts/ProjectileManager.gd") as GDScript
	_projectile_manager = projectile_script.new()
	_projectile_manager.name = "ProjectileManager"
	add_child(_projectile_manager)
	
	# Verify all managers are initialized
	if _chunk_manager == null:
		push_error("[GameServer] ChunkManager failed to initialize!")
	if _npc_manager == null:
		push_error("[GameServer] NPCManager failed to initialize!")
	if _projectile_manager == null:
		push_error("[GameServer] ProjectileManager failed to initialize!")
	
	print("[GameServer] Simulation components initialized")
	print("[GameServer] ChunkManager: %s" % ("OK" if _chunk_manager != null else "FAILED"))
	print("[GameServer] NPCManager: %s" % ("OK" if _npc_manager != null else "FAILED"))
	print("[GameServer] ProjectileManager: %s" % ("OK" if _projectile_manager != null else "FAILED"))


func _start_server() -> void:
	"""Start the TCP server for WebSocket connections, trying multiple ports if needed."""
	var max_port_attempts := 100
	var base_port := listen_port
	
	for attempt in range(max_port_attempts):
		var try_port := base_port + attempt
		print("[GameServer] Trying port %d (attempt %d)..." % [try_port, attempt + 1])
		
		_tcp_server = TCPServer.new()
		# Bind to all interfaces so the Python control plane can connect
		var err := _tcp_server.listen(try_port, "*")
		
		if err == OK:
			listen_port = try_port
			print("[GameServer] TCP server listening on port %d" % listen_port)
			print("[GameServer] WebSocket URL: ws://127.0.0.1:%d" % listen_port)
			# Machine-readable output for Python to parse
			print("GAMESERVER_PORT=%d" % listen_port)
			return
		
		# Port failed, clean up and try next
		_tcp_server = null
		
		if attempt < max_port_attempts - 1:
			print("[GameServer] Port %d unavailable (error %d), trying next..." % [try_port, err])
		else:
			push_error("[GameServer] Failed to bind to any port in range %d-%d!" % [base_port, base_port + max_port_attempts - 1])
	
	push_error("[GameServer] Server failed to start - no available ports!")


func _process(delta: float) -> void:
	# Accept new TCP connections
	if _tcp_server and _tcp_server.is_connection_available():
		var tcp_conn := _tcp_server.take_connection()
		if tcp_conn:
			var peer_id := _next_peer_id
			_next_peer_id += 1
			
			var ws_peer := WebSocketPeer.new()
			var err := ws_peer.accept_stream(tcp_conn)
			if err != OK:
				print("[GameServer] Failed to accept stream for peer %d: %d" % [peer_id, err])
			else:
				_ws_peers[peer_id] = ws_peer
				print("[GameServer] New TCP connection, assigned peer_id %d (state: %d)" % [peer_id, ws_peer.get_ready_state()])
	
	# Poll all WebSocket peers
	var to_remove: Array = []
	for peer_id in _ws_peers.keys():
		var ws_peer: WebSocketPeer = _ws_peers[peer_id]
		ws_peer.poll()
		
		var ws_state := ws_peer.get_ready_state()
		
		match ws_state:
			WebSocketPeer.STATE_CONNECTING:
				# Still doing WebSocket handshake, keep polling
				pass
			
			WebSocketPeer.STATE_OPEN:
				# Receive messages
				while ws_peer.get_available_packet_count() > 0:
					var packet := ws_peer.get_packet()
					var text := packet.get_string_from_utf8()
					
					if text.is_empty():
						continue
					
					print("[GameServer] Received from peer %d: %s" % [peer_id, text.substr(0, 200)])
					
					# Find client_id for this peer
					var client_id: int = _peer_to_client.get(peer_id, 0)
					if client_id > 0:
						_handle_message(client_id, text)
					else:
						# New connection - handle handshake
						_handle_new_peer_message(peer_id, text)
			
			WebSocketPeer.STATE_CLOSING:
				# Peer is closing, wait for closed
				pass
			
			WebSocketPeer.STATE_CLOSED:
				var close_code := ws_peer.get_close_code()
				var close_reason := ws_peer.get_close_reason()
				print("[GameServer] Peer %d closed (code: %d, reason: %s)" % [peer_id, close_code, close_reason])
				var client_id: int = _peer_to_client.get(peer_id, 0)
				if client_id > 0:
					_on_client_disconnected(client_id)
				to_remove.append(peer_id)
	
	# Clean up disconnected peers
	for peer_id in to_remove:
		_ws_peers.erase(peer_id)
		_peer_to_client.erase(peer_id)


func _physics_process(delta: float) -> void:
	# Don't simulate until managers are initialized
	if _projectile_manager == null or _npc_manager == null:
		return
	
	# Fixed timestep simulation
	_tick_accumulator += delta
	
	while _tick_accumulator >= TICK_INTERVAL:
		_tick_accumulator -= TICK_INTERVAL
		_simulate_tick()




func _handle_new_peer_message(peer_id: int, text: String) -> void:
	"""Handle message from a peer that hasn't authenticated yet."""
	var data := Protocol.decode_message(text)
	if data.is_empty():
		return
	
	var msg_type := Protocol.get_message_type(data)
	
	if msg_type == Protocol.ClientMsg.HANDSHAKE:
		_handle_peer_handshake(peer_id, data)
	else:
		print("[GameServer] Peer %d sent non-handshake message before auth" % peer_id)


func _handle_peer_handshake(peer_id: int, data: Dictionary) -> void:
	"""Handle handshake from a new peer."""
	print("[GameServer] Handling handshake from peer %d" % peer_id)
	var protocol_version: int = data.get("protocol_version", 0)
	var session_token: String = data.get("session_token", "")
	
	print("[GameServer] Protocol: %d, Token: %s" % [protocol_version, session_token.left(8) + "..." if session_token else "none"])
	
	# Validate protocol version
	if protocol_version != Protocol.PROTOCOL_VERSION:
		_send_to_peer(peer_id, Protocol.build_handshake_response(
			false, server_tick, 0, "", "Protocol version mismatch"
		))
		return
	
	# Accept any non-empty session token for now
	if session_token.is_empty():
		_send_to_peer(peer_id, Protocol.build_handshake_response(
			false, server_tick, 0, "", "Invalid session token"
		))
		return
	
	# Create client session
	var client_id := _generate_client_id()
	
	var session := ClientSession.new()
	session.client_id = client_id
	session.peer_id = peer_id
	session.state = ClientSession.State.AUTHENTICATED
	session.session_token = session_token
	session.connect_time = Time.get_unix_time_from_system()
	
	_clients[client_id] = session
	_peer_to_client[peer_id] = client_id
	_input_buffers[client_id] = {}
	
	# Spawn player entity
	var entity_id := _spawn_player(client_id)
	session.entity_id = entity_id
	
	# Send success response
	var handshake_response := Protocol.build_handshake_response(
		true, server_tick, entity_id, world_id, ""
	)
	print("[GameServer] Sending handshake response to peer %d: %s" % [peer_id, JSON.stringify(handshake_response).substr(0, 200)])
	_send_to_peer(peer_id, handshake_response)
	
	# Broadcast player joined to other clients
	for other_id in _clients.keys():
		if other_id != client_id:
			var other_session: ClientSession = _clients[other_id]
			if other_session.state == ClientSession.State.AUTHENTICATED:
				_send_to_client(other_id, {
					"type": Protocol.ServerMsg.PLAYER_JOINED,
					"server_tick": server_tick,
					"client_id": client_id,
					"entity_id": entity_id,
				})
	
	print("[GameServer] Client %d (peer %d) authenticated, assigned entity %d" % [client_id, peer_id, entity_id])
	client_authenticated.emit(client_id, session_token)


func _generate_client_id() -> int:
	"""Generate unique client ID."""
	var id := randi() % 1000000 + 1
	while _clients.has(id):
		id = randi() % 1000000 + 1
	return id


func _handle_message(client_id: int, text: String) -> void:
	"""Handle incoming message from client."""
	var data := Protocol.decode_message(text)
	if data.is_empty():
		return
	
	var msg_type := Protocol.get_message_type(data)
	var session: ClientSession = _clients.get(client_id)
	
	if session == null:
		return
	
	match msg_type:
		Protocol.ClientMsg.INPUT_FRAME:
			if session.state == ClientSession.State.AUTHENTICATED:
				_handle_input_frame(client_id, data)
		Protocol.ClientMsg.TERRAFORM_REQUEST:
			if session.state == ClientSession.State.AUTHENTICATED:
				_handle_terraform_request(client_id, data)
		Protocol.ClientMsg.CHUNK_REQUEST:
			if session.state == ClientSession.State.AUTHENTICATED:
				_handle_chunk_request(client_id, data)
		Protocol.ClientMsg.SPELL_CAST_REQUEST:
			if session.state == ClientSession.State.AUTHENTICATED:
				_handle_spell_cast_request(client_id, data)
		Protocol.ClientMsg.PING:
			_handle_ping(client_id, data)
		Protocol.ClientMsg.DISCONNECT:
			_on_client_disconnected(client_id)


func _spawn_player(client_id: int) -> int:
	"""Spawn a player entity for a client."""
	var player := preload("res://server/scripts/ServerPlayer.gd").new()
	player.name = "Player_%d" % client_id
	player.client_id = client_id
	
	# Set spawn position (TODO: load from persistence)
	player.position = Vector3(0, 10, 0)
	
	_physics_world.add_child(player)
	
	var entity_id: int = entity_registry.register_entity(player, Protocol.EntityType.PLAYER)
	return entity_id


func _handle_input_frame(client_id: int, data: Dictionary) -> void:
	"""Handle input frame from client."""
	var session: ClientSession = _clients.get(client_id)
	if session == null:
		return
	
	var input_frame := InputFrame.new()
	input_frame.client_tick = data.get("client_tick", 0)
	input_frame.server_tick_ack = data.get("server_tick_ack", 0)
	input_frame.sequence_id = data.get("sequence_id", 0)
	input_frame.movement = Protocol._array_to_vec3(data.get("movement", [0, 0, 0]))
	input_frame.aim_direction = Protocol._array_to_vec3(data.get("aim_direction", [0, 0, 1]))
	input_frame.sprint = data.get("sprint", false)
	input_frame.fire = data.get("fire", false)
	input_frame.interact = data.get("interact", false)
	input_frame.jump = data.get("jump", false)
	
	# Store in input buffer
	var buffer: Dictionary = _input_buffers.get(client_id, {})
	buffer[server_tick] = input_frame
	
	# Keep only recent inputs (last 1 second worth)
	var min_tick := server_tick - TICK_RATE
	for tick in buffer.keys():
		if tick < min_tick:
			buffer.erase(tick)
	
	# Update last processed sequence
	session.last_input_sequence = input_frame.sequence_id


func _handle_terraform_request(client_id: int, data: Dictionary) -> void:
	"""Handle terraform request from client."""
	var op_type: int = data.get("op_type", 0)
	var center := Protocol._array_to_vec3(data.get("center", [0, 0, 0]))
	var radius: float = data.get("radius", 1.0)
	var material_id: int = data.get("material_id", 1)
	var client_seq: int = data.get("client_sequence_id", 0)
	
	# Apply terraform operation
	var affected_chunks: Array = _chunk_manager.apply_terraform(op_type, center, radius, material_id)
	
	# Broadcast to all clients
	var response := Protocol.build_terraform_applied(
		server_tick, op_type, center, radius, material_id, affected_chunks, client_seq
	)
	_broadcast_message(response)
	
	print("[GameServer] Terraform op %d at %s applied" % [op_type, center])


func _handle_chunk_request(client_id: int, data: Dictionary) -> void:
	"""Handle chunk data request."""
	var chunk_id: Array = data.get("chunk_id", [0, 0, 0])
	var last_version: int = data.get("last_known_version", 0)
	
	var chunk_data: Dictionary = _chunk_manager.get_chunk_data(chunk_id, last_version)
	if chunk_data.is_empty():
		return
	
	_send_to_client(client_id, chunk_data)


func _handle_spell_cast_request(client_id: int, data: Dictionary) -> void:
	"""Handle spell cast request from client."""
	var session: ClientSession = _clients.get(client_id)
	if session == null:
		return
	
	var spell_id: String = data.get("spell_id", "")
	var revision_id: String = data.get("revision_id", "")
	var target_position := Protocol._array_to_vec3(data.get("target_position", [0, 0, 0]))
	var target_entity_id: int = data.get("target_entity_id", 0)
	var extra_params: Dictionary = data.get("extra_params", {})
	
	if spell_id.is_empty():
		_send_to_client(client_id, Protocol.build_error(400, "spell_id required"))
		return
	
	# TODO: Validate spell and revision exist
	# TODO: Validate caster can cast (cooldown, mana, etc.)
	
	# Generate deterministic seed for this cast
	var cast_seed := randi()
	
	# Broadcast spell cast event to all clients
	var cast_event := Protocol.build_spell_cast_event(
		server_tick,
		spell_id,
		revision_id,
		session.entity_id,
		target_position,
		cast_seed,
		extra_params
	)
	_broadcast_message(cast_event)
	
	print("[GameServer] Spell cast: %s by entity %d at %s" % [spell_id, session.entity_id, target_position])


func _handle_ping(client_id: int, data: Dictionary) -> void:
	"""Handle ping request."""
	var client_time: float = data.get("client_time", 0.0)
	var response := Protocol.build_pong(client_time, Time.get_unix_time_from_system(), server_tick)
	_send_to_client(client_id, response)


func _on_client_disconnected(client_id: int) -> void:
	"""Handle client disconnection."""
	var session: ClientSession = _clients.get(client_id)
	if session == null:
		return
	
	# Remove player entity
	if session.entity_id > 0:
		var entity: Node = entity_registry.get_entity(session.entity_id)
		if entity:
			entity_registry.unregister_entity(session.entity_id)
			entity.queue_free()
		
		# Notify other clients
		_broadcast_message({
			"type": Protocol.ServerMsg.PLAYER_LEFT,
			"server_tick": server_tick,
			"client_id": client_id,
			"entity_id": session.entity_id,
		})
	
	_clients.erase(client_id)
	_input_buffers.erase(client_id)
	
	print("[GameServer] Client %d disconnected" % client_id)
	client_disconnected.emit(client_id)


func _simulate_tick() -> void:
	"""Run one simulation tick."""
	server_tick += 1
	
	# Process inputs for all players
	_process_player_inputs()
	
	# Update projectiles
	if _projectile_manager != null:
		_projectile_manager.simulate_tick(server_tick, TICK_INTERVAL)
	
	# Update NPCs (perception, AI)
	if _npc_manager != null:
		_npc_manager.simulate_tick(server_tick, TICK_INTERVAL, entity_registry)
	
	# Broadcast snapshots periodically
	_ticks_since_snapshot += 1
	if _ticks_since_snapshot >= SNAPSHOT_INTERVAL:
		_ticks_since_snapshot = 0
		_broadcast_snapshots()


func _process_player_inputs() -> void:
	"""Process inputs for all connected players."""
	for client_id in _clients.keys():
		var session: ClientSession = _clients[client_id]
		if session.state != ClientSession.State.AUTHENTICATED:
			continue
		
		var player: Node = entity_registry.get_entity(session.entity_id)
		if player == null or not player.has_method("apply_input"):
			continue
		
		# Get input for this tick (or use last input)
		var buffer: Dictionary = _input_buffers.get(client_id, {})
		var input: InputFrame = buffer.get(server_tick)
		
		if input == null:
			# Use most recent input as fallback
			var latest_tick := 0
			for tick in buffer.keys():
				if tick > latest_tick:
					latest_tick = tick
					input = buffer[tick]
		
		if input:
			player.apply_input(input, TICK_INTERVAL)
			
			# Handle fire input -> spawn projectile
			if input.fire and player.can_fire():
				_spawn_projectile(client_id, session.entity_id, player.global_position, input.aim_direction)


func _spawn_projectile(owner_client_id: int, owner_entity_id: int, origin: Vector3, direction: Vector3) -> void:
	"""Spawn a projectile (server authoritative)."""
	var projectile_id: int = _projectile_manager.spawn_projectile(
		owner_entity_id, origin, direction.normalized(), 50.0, 10.0
	)
	
	# Broadcast spawn to all clients
	_broadcast_message(Protocol.build_entity_spawn(
		server_tick,
		projectile_id,
		Protocol.EntityType.PROJECTILE,
		origin,
		Vector3.ZERO,
		{"direction": Protocol._vec3_to_array(direction), "owner": owner_entity_id}
	))


func _broadcast_snapshots() -> void:
	"""Send state snapshots to all authenticated clients."""
	# Collect entity states
	var entities: Array = []
	for entity_id in entity_registry.get_all_entities().keys():
		var entity: Node = entity_registry.get_entity(entity_id)
		if entity == null or not entity is Node3D:
			continue
		
		var entity_type: int = entity.get("entity_type") if "entity_type" in entity else Protocol.EntityType.PLAYER
		var health: float = entity.get("health") if "health" in entity else 100.0
		var velocity: Vector3 = entity.get("velocity") if "velocity" in entity else Vector3.ZERO
		
		entities.append(Protocol.serialize_entity_state(
			entity_id,
			entity_type,
			entity.global_position,
			entity.rotation,
			velocity,
			health
		))
	
	# Send personalized snapshot to each client
	for client_id in _clients.keys():
		var session: ClientSession = _clients[client_id]
		if session.state != ClientSession.State.AUTHENTICATED:
			continue
		
		var player: Node = entity_registry.get_entity(session.entity_id)
		var player_state: Dictionary = {}
		
		if player:
			var velocity: Vector3 = player.get("velocity") if "velocity" in player else Vector3.ZERO
			var on_ground: bool = player.get("on_ground") if "on_ground" in player else true
			player_state = Protocol.serialize_player_state(
				session.last_input_sequence,
				player.global_position,
				velocity,
				on_ground
			)
		
		var snapshot := Protocol.build_state_snapshot(server_tick, entities, player_state)
		_send_to_client(client_id, snapshot)


func _send_to_peer(peer_id: int, data: Dictionary) -> void:
	"""Send message to a specific peer."""
	var ws_peer: WebSocketPeer = _ws_peers.get(peer_id)
	if ws_peer == null:
		return
	
	if ws_peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	
	var json_str := Protocol.encode_message(data)
	ws_peer.send_text(json_str)
	# Only log non-snapshot messages to reduce spam
	var msg_type: int = data.get("type", 0)
	if msg_type != Protocol.ServerMsg.STATE_SNAPSHOT:
		print("[GameServer] Sent to peer %d: %s" % [peer_id, json_str.substr(0, 100)])


func _send_to_client(client_id: int, data: Dictionary) -> void:
	"""Send message to a specific client."""
	var session: ClientSession = _clients.get(client_id)
	if session == null or session.peer_id == 0:
		return
	
	_send_to_peer(session.peer_id, data)


func _broadcast_message(data: Dictionary, exclude_client: int = -1) -> void:
	"""Broadcast message to all authenticated clients."""
	for client_id in _clients.keys():
		if client_id == exclude_client:
			continue
		
		var session: ClientSession = _clients[client_id]
		if session.state == ClientSession.State.AUTHENTICATED:
			_send_to_client(client_id, data)


# =============================================================================
# Admin API (for Python control plane)
# =============================================================================

func get_server_state() -> Dictionary:
	"""Get current server state for admin/persistence."""
	return {
		"world_id": world_id,
		"server_tick": server_tick,
		"client_count": _clients.size(),
		"entity_count": entity_registry.get_entity_count(),
	}


func load_world_state(state: Dictionary) -> void:
	"""Load world state from persistence."""
	# Load chunks
	if state.has("chunks"):
		_chunk_manager.load_chunks(state["chunks"])
	
	# Load entities
	if state.has("entities"):
		for entity_data in state["entities"]:
			# TODO: Spawn entities from saved data
			pass
	
	print("[GameServer] World state loaded")


func save_world_state() -> Dictionary:
	"""Save current world state for persistence."""
	var chunks: Array = _chunk_manager.save_chunks()
	var entities: Array = []
	
	# Save entity states (excluding players)
	for entity_id in entity_registry.get_all_entities().keys():
		var entity: Node = entity_registry.get_entity(entity_id)
		if entity == null:
			continue
		
		var entity_type: int = entity.get("entity_type") if "entity_type" in entity else 0
		if entity_type == Protocol.EntityType.PLAYER:
			continue  # Don't save player entities
		
		entities.append({
			"entity_id": entity_id,
			"entity_type": entity_type,
			"position": Protocol._vec3_to_array(entity.global_position),
			"rotation": Protocol._vec3_to_array(entity.rotation),
		})
	
	return {
		"world_id": world_id,
		"server_tick": server_tick,
		"chunks": chunks,
		"entities": entities,
	}


func shutdown() -> void:
	"""Clean shutdown."""
	print("[GameServer] Shutting down...")
	
	# Disconnect all WebSocket peers
	for peer_id in _ws_peers.keys():
		var ws_peer: WebSocketPeer = _ws_peers[peer_id]
		ws_peer.close()
	_ws_peers.clear()
	
	# Stop TCP server
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null
	
	_clients.clear()
	_peer_to_client.clear()
	
	print("[GameServer] Shutdown complete")
	get_tree().quit()


# =============================================================================
# Helper Classes
# =============================================================================

class ClientSession:
	enum State { CONNECTED, AUTHENTICATED, DISCONNECTED }
	
	var client_id: int = 0
	var peer_id: int = 0  # Multiplayer peer ID
	var state: State = State.CONNECTED
	var session_token: String = ""
	var entity_id: int = 0
	var last_input_sequence: int = 0
	var connect_time: float = 0.0


class InputFrame:
	var client_tick: int = 0
	var server_tick_ack: int = 0
	var sequence_id: int = 0
	var movement: Vector3 = Vector3.ZERO
	var aim_direction: Vector3 = Vector3.FORWARD
	var sprint: bool = false
	var fire: bool = false
	var interact: bool = false
	var jump: bool = false
