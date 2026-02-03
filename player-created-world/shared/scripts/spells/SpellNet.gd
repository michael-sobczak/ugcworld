extends Node

## SpellNet singleton - handles network communication for the spell system.
## Wraps WebSocket events for spell operations.

signal server_connected
signal server_disconnected
signal job_progress(job_id: String, stage: String, pct: int, message: String, extras: Dictionary)
signal build_started(job_id: String, spell_id: String)
signal spell_revision_ready(spell_id: String, revision_id: String, manifest: Dictionary)
signal spell_active_update(spell_id: String, revision_id: String, channel: String, manifest: Dictionary)
signal cast_event(spell_id: String, revision_id: String, caster_id: String, cast_params: Dictionary, seed_value: int)
signal file_received(spell_id: String, revision_id: String, path: String, content: PackedByteArray)
signal server_error(message: String)

## Reference to Net singleton for WebSocket communication
var _net: Node = null

## Track if we're connected
var _is_connected := false



func _ready() -> void:
	call_deferred("_init_references")


func _init_references() -> void:
	_net = get_node_or_null("/root/Net")
	
	if _net:
		_net.connected_to_control_plane.connect(_on_connected)
		_net.disconnected_from_server.connect(_on_disconnected)
		_net.message_received.connect(_on_message_received)
		
		_is_connected = _net.is_connected_to_server()


func _on_connected() -> void:
	_is_connected = true
	server_connected.emit()


func _on_disconnected() -> void:
	_is_connected = false
	server_disconnected.emit()


func _on_message_received(data: Dictionary) -> void:
	"""Handle incoming messages from server."""
	var msg_type = data.get("type", "")  # Can be int or string
	
	match msg_type:
		# Job progress
		"job.progress":
			_handle_job_progress(data)
		
		# Build started
		"spell.build_started":
			build_started.emit(data.get("job_id", ""), data.get("spell_id", ""))
		
		# Revision ready for download
		"spell.revision_ready":
			var manifest: Dictionary = data.get("manifest", {})
			spell_revision_ready.emit(
				data.get("spell_id", ""),
				data.get("revision_id", ""),
				manifest
			)
		
		# Active revision update
		"spell.active_update":
			var manifest: Dictionary = data.get("manifest", {})
			spell_active_update.emit(
				data.get("spell_id", ""),
				data.get("revision_id", ""),
				data.get("channel", "beta"),
				manifest
			)
		
		# Cast event (another player cast a spell)
		"spell.cast_event":
			_handle_cast_event(data)
		
		# File content received
		"content.file":
			_handle_file_received(data)
		
		# Manifest received
		"content.manifest":
			_handle_manifest_received(data)
		
		# Error from server
		"error":
			server_error.emit(data.get("message", "Unknown error"))


func _handle_job_progress(data: Dictionary) -> void:
	"""Handle job progress update."""
	var extras: Dictionary = {}
	if data.has("revision_id"):
		extras["revision_id"] = data["revision_id"]
	if data.has("manifest"):
		extras["manifest"] = data["manifest"]
	
	job_progress.emit(
		data.get("job_id", ""),
		data.get("stage", ""),
		data.get("pct", 0),
		data.get("message", ""),
		extras
	)


func _handle_cast_event(data: Dictionary) -> void:
	"""Handle a spell cast event from the server."""
	cast_event.emit(
		data.get("spell_id", ""),
		data.get("revision_id", ""),
		data.get("caster_id", ""),
		data.get("cast_params", {}),
		data.get("seed", 0)
	)


func _handle_file_received(data: Dictionary) -> void:
	"""Handle file content received from server."""
	var spell_id: String = data.get("spell_id", "")
	var revision_id: String = data.get("revision_id", "")
	var file_path: String = data.get("path", "")
	var content_b64: String = data.get("content", "")
	
	print("[SpellNet] Received file: ", spell_id, "/", revision_id, "/", file_path)
	
	# Decode base64 content
	var content: PackedByteArray = Marshalls.base64_to_raw(content_b64)
	
	# Notify cache (it will save the file and track progress)
	var cache: Node = get_node_or_null("/root/SpellCache")
	if cache:
		cache.on_file_received(spell_id, revision_id, file_path, content)
	
	file_received.emit(spell_id, revision_id, file_path, content)


func _handle_manifest_received(data: Dictionary) -> void:
	"""Handle manifest received from server."""
	var spell_id: String = data.get("spell_id", "")
	var revision_id: String = data.get("revision_id", "")
	var manifest: Dictionary = data.get("manifest", {})
	
	# Save to cache
	var cache: Node = get_node_or_null("/root/SpellCache")
	if cache:
		cache.save_manifest(spell_id, revision_id, manifest)
	
	# Trigger download of remaining files
	if cache:
		cache.ensure_revision_cached(spell_id, revision_id, manifest)


# ============================================================================
# Outgoing Requests
# ============================================================================

func create_draft(spell_id: String = "") -> void:
	"""Create a new spell draft."""
	_send({"type": "spell.create_draft", "spell_id": spell_id})


func start_build(spell_id: String, options: Dictionary = {}) -> void:
	"""
	Start a build job for a spell.
	
	Options:
		prompt: String - description/prompt for generation
		code: String - custom code content (optional)
		metadata: Dictionary - name, description, tags
		parent_revision_id: String - fork from existing revision
	"""
	var msg: Dictionary = {
		"type": "spell.start_build",
		"spell_id": spell_id
	}
	
	if options.has("prompt"):
		msg["prompt"] = options["prompt"]
	if options.has("code"):
		msg["code"] = options["code"]
	if options.has("metadata") or options.has("parent_revision_id"):
		msg["options"] = {}
		if options.has("metadata"):
			msg["options"]["metadata"] = options["metadata"]
		if options.has("parent_revision_id"):
			msg["options"]["parent_revision_id"] = options["parent_revision_id"]
	
	_send(msg)


func publish_revision(spell_id: String, revision_id: String, channel: String = "beta") -> void:
	"""Publish a revision to a channel."""
	_send({
		"type": "spell.publish",
		"spell_id": spell_id,
		"revision_id": revision_id,
		"channel": channel
	})


func request_manifest(spell_id: String, revision_id: String) -> void:
	"""Request manifest for a revision."""
	_send({
		"type": "content.get_manifest",
		"spell_id": spell_id,
		"revision_id": revision_id
	})


func request_file(spell_id: String, revision_id: String, file_path: String) -> void:
	"""Request a specific file from a revision."""
	_send({
		"type": "content.get_file",
		"spell_id": spell_id,
		"revision_id": revision_id,
		"path": file_path
	})


func request_file_list(spell_id: String, revision_id: String) -> void:
	"""Request list of files in a revision."""
	_send({
		"type": "content.list_files",
		"spell_id": spell_id,
		"revision_id": revision_id
	})


func cast_spell(spell_id: String, revision_id: String, cast_params: Dictionary) -> void:
	"""
	Request to cast a spell.
	Server will validate and broadcast cast_event to all clients.
	"""
	_send({
		"type": "spell.cast_request",
		"spell_id": spell_id,
		"revision_id": revision_id,
		"cast_params": cast_params
	})


func list_spells() -> void:
	"""Request list of all spells."""
	_send({"type": "spell.list"})


func get_revisions(spell_id: String) -> void:
	"""Request revisions for a spell."""
	_send({
		"type": "spell.get_revisions",
		"spell_id": spell_id
	})


# ============================================================================
# Helpers
# ============================================================================

func _send(data: Dictionary) -> void:
	"""Send a message to the server."""
	if not _net or not _is_connected:
		push_warning("[SpellNet] Not connected, cannot send: ", data.get("type", ""))
		return
	
	_net.send_message(data)


func is_server_connected() -> bool:
	"""Check if connected to server."""
	return _is_connected
