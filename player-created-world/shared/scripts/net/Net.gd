extends Node

## WebSocket client for connecting to the Python backend.
## This is a client-only implementation - no server hosting capability.

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 5000
const LOCALHOST_URL := "ws://127.0.0.1:5000"
const PRODUCTION_URL := "wss://ugc-world-backend.fly.dev"

signal connected_to_server
signal disconnected_from_server
signal connection_failed
signal message_received(data: Dictionary)

var _socket: WebSocketPeer = null
var _connected := false
var _connecting := false

## Server URL
var server_url: String = ""


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
	message_received.emit(data)


func is_connected_to_server() -> bool:
	return _connected


func is_connecting() -> bool:
	return _connecting


func ping() -> void:
	"""Send a ping to the server."""
	send_message({"type": "ping"})
