extends Node

const PROTOCOL := preload("res://shared/scripts/protocol/Protocol.gd")

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

## HTTP fallback for control plane when Socket.IO isn't available
const JOB_POLL_INTERVAL := 0.5
const JOB_TIMEOUT_SECONDS := 60.0



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
	var msg_type: Variant = data.get("type", "")  # Can be int, float, or string
	if msg_type is float:
		msg_type = int(msg_type)
	
	match msg_type:
		# Game server cast event (Protocol.ServerMsg.SPELL_CAST_EVENT)
		112:
			_handle_cast_event(data)
		
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
	var caster_id := str(data.get("caster_id", ""))
	if caster_id == "" and data.has("caster_entity_id"):
		caster_id = str(data.get("caster_entity_id"))
	var cast_params: Dictionary = data.get("cast_params", {}) as Dictionary
	if cast_params.is_empty():
		cast_params = data.get("extra_params", {}) as Dictionary
	if data.has("target_position"):
		cast_params["target_position"] = _normalize_target_position(data.get("target_position"))
	cast_event.emit(
		data.get("spell_id", ""),
		data.get("revision_id", ""),
		caster_id,
		cast_params,
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
	
	if _use_http_fallback():
		await _start_build_http(spell_id, msg)
		return
	_send(msg)


func publish_revision(spell_id: String, revision_id: String, channel: String = "beta") -> void:
	"""Publish a revision to a channel."""
	if _use_http_fallback():
		await _publish_revision_http(spell_id, revision_id, channel)
		return
	_send({
		"type": "spell.publish",
		"spell_id": spell_id,
		"revision_id": revision_id,
		"channel": channel
	})


func request_manifest(spell_id: String, revision_id: String) -> void:
	"""Request manifest for a revision."""
	if _use_http_fallback():
		await _request_manifest_http(spell_id, revision_id)
		return
	_send({
		"type": "content.get_manifest",
		"spell_id": spell_id,
		"revision_id": revision_id
	})


func request_file(spell_id: String, revision_id: String, file_path: String) -> void:
	"""Request a specific file from a revision."""
	if _use_http_fallback():
		await _request_file_http(spell_id, revision_id, file_path)
		return
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
	if _net and _net.has_method("is_in_world") and _net.is_in_world():
		var target_position := Vector3.ZERO
		var pos_data: Variant = cast_params.get("target_position", {})
		if pos_data is Dictionary:
			var pos_dict: Dictionary = pos_data as Dictionary
			target_position = Vector3(
				float(pos_dict.get("x", 0)),
				float(pos_dict.get("y", 0)),
				float(pos_dict.get("z", 0))
			)
		elif pos_data is Array and (pos_data as Array).size() >= 3:
			var pos_array: Array = pos_data as Array
			target_position = Vector3(float(pos_array[0]), float(pos_array[1]), float(pos_array[2]))
		elif pos_data is Vector3:
			target_position = pos_data
		var target_entity_id := int(cast_params.get("target_entity_id", 0))
		var extra_params: Dictionary = cast_params.duplicate(true)
		extra_params.erase("target_position")
		extra_params.erase("target_entity_id")
		var msg := PROTOCOL.build_spell_cast_request(spell_id, revision_id, target_position, target_entity_id, extra_params)
		_net.send_message(msg)
		return
	_send({
		"type": "spell.cast_request",
		"spell_id": spell_id,
		"revision_id": revision_id,
		"cast_params": cast_params
	})


func list_spells() -> void:
	"""Request list of all spells."""
	if _use_http_fallback():
		await _list_spells_http()
		return
	_send({"type": "spell.list"})


func get_revisions(spell_id: String) -> void:
	"""Request revisions for a spell."""
	if _use_http_fallback():
		await _get_revisions_http(spell_id)
		return
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


# ============================================================================
# HTTP fallback helpers
# ============================================================================

func _use_http_fallback() -> bool:
	return _net != null and _net.control_plane_url.begins_with("http")

func _http_request(path: String, method: int, body: Dictionary = {}) -> Dictionary:
	if _net == null:
		return {"ok": false, "error": "Net not available"}
	var url: String = _net.control_plane_url.trim_suffix("/") + path
	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)
	var headers: Array[String] = ["Content-Type: application/json"]
	if _net.session_token != "":
		headers.append("Authorization: Bearer " + _net.session_token)
	var payload: String = "" if body.is_empty() else JSON.stringify(body)
	var err: int = http.request(url, headers, method, payload)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "HTTP request failed"}
	var result: Array = await http.request_completed
	http.queue_free()
	var response_code := int(result[1])
	var response_body: PackedByteArray = result[3]
	var parsed: Variant = JSON.parse_string(response_body.get_string_from_utf8())
	return {
		"ok": response_code >= 200 and response_code < 300,
		"code": response_code,
		"data": (parsed as Dictionary) if parsed is Dictionary else {}
	}

func _start_build_http(spell_id: String, msg: Dictionary) -> void:
	var body: Dictionary = {
		"prompt": msg.get("prompt", ""),
		"code": msg.get("code", ""),
		"options": msg.get("options", {})
	}
	var response: Dictionary = await _http_request("/api/spells/%s/build" % spell_id, HTTPClient.METHOD_POST, body)
	if not response.get("ok", false):
		server_error.emit("Build request failed")
		return
	var data: Dictionary = response.get("data", {}) as Dictionary
	var job_id: String = str(data.get("job_id", ""))
	if job_id == "":
		server_error.emit("Build request returned no job_id")
		return
	build_started.emit(job_id, spell_id)
	await _poll_job(job_id, spell_id)

func _poll_job(job_id: String, spell_id: String) -> void:
	var start_time: int = Time.get_ticks_msec()
	while (Time.get_ticks_msec() - start_time) < int(JOB_TIMEOUT_SECONDS * 1000.0):
		var response: Dictionary = await _http_request("/api/jobs/%s" % job_id, HTTPClient.METHOD_GET)
		if response.get("ok", false):
			var job: Dictionary = response.get("data", {}) as Dictionary
			var status := str(job.get("status", ""))
			var stage := str(job.get("stage", ""))
			var pct := int(job.get("progress_pct", 0))
			var error_message := str(job.get("error_message", ""))
			var revision_id := str(job.get("result_revision_id", ""))
			job_progress.emit(job_id, stage, pct, status, {})
			if (status == "completed" or status == "done") and revision_id != "":
				var manifest := await _fetch_manifest_http(spell_id, revision_id)
				var extras := {
					"revision_id": revision_id,
					"manifest": manifest
				}
				job_progress.emit(job_id, "done", 100, "done", extras)
				spell_revision_ready.emit(spell_id, revision_id, manifest)
				return
			if status == "error":
				server_error.emit(error_message if error_message != "" else "Build failed")
				return
		await get_tree().create_timer(JOB_POLL_INTERVAL).timeout
	server_error.emit("Build timed out")

func _fetch_manifest_http(spell_id: String, revision_id: String) -> Dictionary:
	var response: Dictionary = await _http_request("/api/spells/%s/revisions/%s/manifest" % [spell_id, revision_id], HTTPClient.METHOD_GET)
	if response.get("ok", false):
		var data: Dictionary = response.get("data", {}) as Dictionary
		return data.get("manifest", {}) as Dictionary
	return {}

func _publish_revision_http(spell_id: String, revision_id: String, channel: String) -> void:
	var body: Dictionary = {"revision_id": revision_id, "channel": channel}
	var response: Dictionary = await _http_request("/api/spells/%s/publish" % spell_id, HTTPClient.METHOD_POST, body)
	if not response.get("ok", false):
		server_error.emit("Publish failed")
		return
	var data: Dictionary = response.get("data", {}) as Dictionary
	spell_active_update.emit(
		data.get("spell_id", spell_id),
		data.get("revision_id", revision_id),
		data.get("channel", channel),
		data.get("manifest", {})
	)

func _request_manifest_http(spell_id: String, revision_id: String) -> void:
	var manifest := await _fetch_manifest_http(spell_id, revision_id)
	_handle_manifest_received({
		"spell_id": spell_id,
		"revision_id": revision_id,
		"manifest": manifest
	})

func _request_file_http(spell_id: String, revision_id: String, file_path: String) -> void:
	if _net == null:
		return
	var url: String = _net.control_plane_url.trim_suffix("/") + "/api/spells/%s/revisions/%s/files/%s" % [
		spell_id, revision_id, file_path
	]
	var http: HTTPRequest = HTTPRequest.new()
	add_child(http)
	var err: int = http.request(url, [], HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return
	var result: Array = await http.request_completed
	http.queue_free()
	var response_code := int(result[1])
	if response_code < 200 or response_code >= 300:
		return
	var content: PackedByteArray = result[3]
	var cache: Node = get_node_or_null("/root/SpellCache")
	if cache:
		cache.on_file_received(spell_id, revision_id, file_path, content)
	file_received.emit(spell_id, revision_id, file_path, content)

func _list_spells_http() -> void:
	var response: Dictionary = await _http_request("/api/spells", HTTPClient.METHOD_GET)
	if not response.get("ok", false):
		return
	var data: Dictionary = response.get("data", {}) as Dictionary
	_net.message_received.emit({"type": "spell.list_result", "spells": data.get("spells", [])})

func _get_revisions_http(spell_id: String) -> void:
	var response: Dictionary = await _http_request("/api/spells/%s/revisions" % spell_id, HTTPClient.METHOD_GET)
	if not response.get("ok", false):
		return
	var data: Dictionary = response.get("data", {}) as Dictionary
	_net.message_received.emit({
		"type": "spell.revisions_result",
		"spell_id": spell_id,
		"revisions": data.get("revisions", [])
	})

func _normalize_target_position(value: Variant) -> Dictionary:
	if value is Dictionary:
		var pos_dict: Dictionary = value as Dictionary
		return {
			"x": float(pos_dict.get("x", 0)),
			"y": float(pos_dict.get("y", 0)),
			"z": float(pos_dict.get("z", 0))
		}
	if value is Array and (value as Array).size() >= 3:
		var pos_array: Array = value as Array
		return {
			"x": float(pos_array[0]),
			"y": float(pos_array[1]),
			"z": float(pos_array[2])
		}
	if value is Vector3:
		return {"x": value.x, "y": value.y, "z": value.z}
	return {"x": 0.0, "y": 0.0, "z": 0.0}
