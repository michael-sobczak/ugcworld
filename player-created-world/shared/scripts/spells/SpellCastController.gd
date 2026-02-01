extends Node

## SpellCastController - manages spell casting for the local player.
## Handles the flow from cast request to spell execution.

signal spell_cast_started(spell_id: String, revision_id: String)
signal spell_cast_complete(spell_id: String, revision_id: String)
signal spell_cast_failed(spell_id: String, error_msg: String)

## Currently active spells (for on_tick calls)
## Array of { module: SpellModule, context: SpellContext, start_time: float }
var _active_spells: Array = []

## Pending casts waiting for spell to load
var _pending_casts: Array = []

## Reference to singletons
var _spell_net: Node = null
var _spell_registry: Node = null
var _spell_loader: Node = null

## Scene root for spawning (set externally)
var scene_root: Node = null


func _ready() -> void:
	call_deferred("_init_references")


func _init_references() -> void:
	_spell_net = get_node_or_null("/root/SpellNet")
	_spell_registry = get_node_or_null("/root/SpellRegistry")
	_spell_loader = get_node_or_null("/root/SpellLoader")
	
	if _spell_net:
		_spell_net.cast_event.connect(_on_cast_event)
		_spell_net.spell_active_update.connect(_on_active_update)
		_spell_net.spell_revision_ready.connect(_on_revision_ready)
	
	if _spell_registry:
		_spell_registry.spell_loaded.connect(_on_spell_loaded)


func _process(delta: float) -> void:
	# Tick active spells
	_tick_active_spells(delta)


# ============================================================================
# Cast Initiation
# ============================================================================

func cast_spell(spell_id: String, target_position: Vector3, extra_params: Dictionary = {}) -> void:
	"""
	Initiate a spell cast. Sends request to server.
	Server will broadcast cast_event which triggers actual execution.
	"""
	if not _spell_net:
		spell_cast_failed.emit(spell_id, "SpellNet not available")
		return
	
	if not _spell_net.is_server_connected():
		spell_cast_failed.emit(spell_id, "Not connected to server")
		return
	
	# Get active revision for this spell
	var revision_id: String = ""
	if _spell_registry:
		revision_id = _spell_registry.get_active_revision(spell_id)
	
	if revision_id.is_empty():
		spell_cast_failed.emit(spell_id, "No active revision for spell: " + spell_id)
		return
	
	# Build cast params
	var cast_params: Dictionary = {
		"target_position": {
			"x": target_position.x,
			"y": target_position.y,
			"z": target_position.z
		}
	}
	
	# Merge extra params
	for key: String in extra_params:
		cast_params[key] = extra_params[key]
	
	print("[SpellCast] Requesting cast: ", spell_id, " at ", target_position)
	_spell_net.cast_spell(spell_id, revision_id, cast_params)


# ============================================================================
# Cast Event Handling
# ============================================================================

func _on_cast_event(spell_id: String, revision_id: String, caster_id: String, cast_params: Dictionary, seed_value: int) -> void:
	"""Handle a spell cast event from the server (could be from us or another player)."""
	print("[SpellCast] Cast event: ", spell_id, " rev ", revision_id, " by ", caster_id)
	
	spell_cast_started.emit(spell_id, revision_id)
	
	# Ensure the spell is loaded
	if _spell_registry:
		if _spell_registry.is_spell_loaded(spell_id, revision_id):
			_execute_cast(spell_id, revision_id, caster_id, cast_params, seed_value)
		else:
			# Need to load first, then execute
			# Store pending cast
			var pending: Dictionary = {
				"spell_id": spell_id,
				"revision_id": revision_id,
				"caster_id": caster_id,
				"cast_params": cast_params,
				"seed": seed_value
			}
			
			# Get manifest and ensure loaded
			var manifest: Dictionary = _spell_registry.get_manifest(spell_id, revision_id)
			_spell_registry.ensure_spell_loaded(spell_id, revision_id, manifest)
			
			# Store as pending (will be executed when spell_loaded fires)
			_pending_casts.append(pending)


func _on_spell_loaded(spell_id: String, revision_id: String) -> void:
	"""Handle spell loaded - execute any pending casts."""
	print("[SpellCast] Spell loaded: ", spell_id, "/", revision_id, " - pending casts: ", _pending_casts.size())
	
	var to_execute: Array = []
	var remaining: Array = []
	
	for pending: Dictionary in _pending_casts:
		if pending["spell_id"] == spell_id and pending["revision_id"] == revision_id:
			to_execute.append(pending)
		else:
			remaining.append(pending)
	
	_pending_casts = remaining
	
	print("[SpellCast] Executing ", to_execute.size(), " pending casts for ", spell_id)
	
	for pending: Dictionary in to_execute:
		_execute_cast(
			pending["spell_id"],
			pending["revision_id"],
			pending["caster_id"],
			pending["cast_params"],
			pending["seed"]
		)


func _execute_cast(spell_id: String, revision_id: String, caster_id: String, cast_params: Dictionary, seed_value: int) -> void:
	"""Execute a spell cast after ensuring it's loaded."""
	if not _spell_registry:
		spell_cast_failed.emit(spell_id, "SpellRegistry not available")
		return
	
	# Get the spell module
	var module: SpellModule = _spell_registry.get_spell_module(spell_id, revision_id)
	if not module:
		spell_cast_failed.emit(spell_id, "Failed to get spell module")
		return
	
	# Get manifest
	var manifest: Dictionary = _spell_registry.get_manifest(spell_id, revision_id)
	
	# Create context
	var ctx: SpellContext = SpellContext.new()
	ctx.caster_id = caster_id
	ctx.random_seed = seed_value
	ctx.rng.seed = seed_value
	ctx.manifest = manifest
	ctx.cast_time = Time.get_unix_time_from_system()
	
	# Parse cast params
	var pos_data: Variant = cast_params.get("target_position", {})
	if pos_data is Dictionary:
		var pos_dict: Dictionary = pos_data as Dictionary
		ctx.target_position = Vector3(
			float(pos_dict.get("x", 0)),
			float(pos_dict.get("y", 0)),
			float(pos_dict.get("z", 0))
		)
	
	ctx.target_entity_id = cast_params.get("target_entity_id", "")
	ctx.params = cast_params
	
	# Create world adapter with assets
	if _spell_loader and scene_root:
		ctx.world = _spell_loader.create_world_adapter(spell_id, revision_id, manifest, scene_root)
	else:
		ctx.world = WorldAPIAdapter.new(scene_root)
	
	# Execute the cast!
	print("[SpellCast] Executing: ", spell_id, " on_cast()")
	
	module.on_cast(ctx)
	
	# Check if spell has ongoing effects (on_tick)
	if module.has_method("on_tick"):
		_active_spells.append({
			"module": module,
			"context": ctx,
			"start_time": ctx.cast_time,
			"spell_id": spell_id,
			"revision_id": revision_id
		})
	
	spell_cast_complete.emit(spell_id, revision_id)


# ============================================================================
# Active Spell Management
# ============================================================================

func _tick_active_spells(delta: float) -> void:
	"""Call on_tick for all active spells."""
	for spell_data: Dictionary in _active_spells:
		var module: SpellModule = spell_data["module"]
		var ctx: SpellContext = spell_data["context"]
		ctx.tick_index += 1
		
		module.on_tick(ctx, delta)


func cancel_spell(spell_id: String) -> void:
	"""Cancel an active spell."""
	var to_cancel: Array = []
	var remaining: Array = []
	
	for spell_data: Dictionary in _active_spells:
		if spell_data["spell_id"] == spell_id:
			to_cancel.append(spell_data)
		else:
			remaining.append(spell_data)
	
	_active_spells = remaining
	
	for spell_data: Dictionary in to_cancel:
		var module: SpellModule = spell_data["module"]
		var ctx: SpellContext = spell_data["context"]
		module.on_cancel(ctx)


func cancel_all_spells() -> void:
	"""Cancel all active spells."""
	for spell_data: Dictionary in _active_spells:
		var module: SpellModule = spell_data["module"]
		var ctx: SpellContext = spell_data["context"]
		module.on_cancel(ctx)
	
	_active_spells.clear()


# ============================================================================
# Event Handlers
# ============================================================================

func _on_active_update(spell_id: String, revision_id: String, channel: String, manifest: Dictionary) -> void:
	"""Handle active revision update from server."""
	if _spell_registry:
		_spell_registry.set_active_revision(spell_id, channel, revision_id)
		
		# Pre-load the spell so it's ready to cast
		_spell_registry.ensure_spell_loaded(spell_id, revision_id, manifest)


func _on_revision_ready(spell_id: String, revision_id: String, manifest: Dictionary) -> void:
	"""Handle new revision ready notification."""
	print("[SpellCast] New revision ready: ", spell_id, "/", revision_id)
	
	# Pre-load
	if _spell_registry:
		_spell_registry.ensure_spell_loaded(spell_id, revision_id, manifest)
