extends Node

## SpellRegistry singleton - maps spell IDs to active revisions and loaded modules.
## Provides the main interface for spell lookup and instantiation.

signal spell_updated(spell_id: String, revision_id: String)
signal spell_loaded(spell_id: String, revision_id: String)
signal spell_load_failed(spell_id: String, revision_id: String, error: String)

## Tracks active revision per spell (updated by server)
## spell_id -> { "draft": rev_id, "beta": rev_id, "stable": rev_id }
var _active_revisions: Dictionary = {}

## Loaded spell modules cache
## "spell_id/revision_id" -> SpellModule instance
var _loaded_modules: Dictionary = {}

## Manifests cache
## "spell_id/revision_id" -> manifest Dictionary
var _manifests: Dictionary = {}

## Reference to SpellCache
var _cache: Node = null

## Reference to SpellLoader  
var _loader: Node = null


func _ready() -> void:
	# Get references to other spell singletons
	call_deferred("_init_references")


func _init_references() -> void:
	_cache = get_node_or_null("/root/SpellCache")
	_loader = get_node_or_null("/root/SpellLoader")
	
	if _cache:
		_cache.download_complete.connect(_on_download_complete)
		_cache.download_failed.connect(_on_download_failed)


# ============================================================================
# Active Revision Management
# ============================================================================

func set_active_revision(spell_id: String, channel: String, revision_id: String) -> void:
	"""Set the active revision for a spell on a channel."""
	if not _active_revisions.has(spell_id):
		_active_revisions[spell_id] = {}
	
	_active_revisions[spell_id][channel] = revision_id
	print("[SpellRegistry] Active revision: ", spell_id, " [", channel, "] = ", revision_id)
	spell_updated.emit(spell_id, revision_id)


func get_active_revision(spell_id: String, channel: String = "beta") -> String:
	"""Get the active revision ID for a spell, with fallback."""
	var spell_revs: Dictionary = _active_revisions.get(spell_id, {})
	
	# Try requested channel first
	if spell_revs.has(channel):
		return spell_revs[channel]
	
	# Fallback order: beta -> stable -> draft
	for fallback_channel in ["beta", "stable", "draft"]:
		if spell_revs.has(fallback_channel):
			return spell_revs[fallback_channel]
	
	return ""


func list_registered_spells() -> Array[String]:
	"""List all spells with known active revisions."""
	var spells: Array[String] = []
	for spell_id in _active_revisions.keys():
		spells.append(spell_id as String)
	return spells


# ============================================================================
# Spell Loading
# ============================================================================

func ensure_spell_loaded(spell_id: String, revision_id: String, manifest: Dictionary = {}) -> void:
	"""
	Ensure a spell revision is downloaded and loaded.
	Emits spell_loaded or spell_load_failed when complete.
	"""
	var key := "%s/%s" % [spell_id, revision_id]
	
	# Already loaded?
	if _loaded_modules.has(key):
		spell_loaded.emit(spell_id, revision_id)
		return
	
	# Save manifest if provided
	if not manifest.is_empty():
		_manifests[key] = manifest
	
	# Ensure cached
	if _cache:
		if _cache.revision_cached(spell_id, revision_id):
			# Already cached, load it
			_load_spell_module(spell_id, revision_id)
		else:
			# Need to download first
			_cache.ensure_revision_cached(spell_id, revision_id, manifest)
	else:
		spell_load_failed.emit(spell_id, revision_id, "SpellCache not available")


func _on_download_complete(spell_id: String, revision_id: String) -> void:
	"""Called when a spell revision is fully cached."""
	print("[SpellRegistry] Download complete, loading module: ", spell_id, "/", revision_id)
	_load_spell_module(spell_id, revision_id)


func _on_download_failed(spell_id: String, revision_id: String, error: String) -> void:
	"""Called when download fails."""
	spell_load_failed.emit(spell_id, revision_id, error)


func _load_spell_module(spell_id: String, revision_id: String) -> void:
	"""Load the spell module from cache."""
	print("[SpellRegistry] Loading spell module: ", spell_id, "/", revision_id)
	
	if not _loader:
		push_error("[SpellRegistry] SpellLoader not available")
		spell_load_failed.emit(spell_id, revision_id, "SpellLoader not available")
		return
	
	var key: String = "%s/%s" % [spell_id, revision_id]
	
	# Get manifest
	var manifest: Dictionary = _manifests.get(key, {})
	if manifest.is_empty() and _cache:
		manifest = _cache.get_manifest(spell_id, revision_id)
	
	if manifest.is_empty():
		push_error("[SpellRegistry] No manifest found for ", spell_id, "/", revision_id)
		spell_load_failed.emit(spell_id, revision_id, "No manifest found")
		return
	
	_manifests[key] = manifest
	print("[SpellRegistry] Got manifest, entrypoint: ", manifest.get("entrypoint", "unknown"))
	
	# Load via SpellLoader
	var module: SpellModule = _loader.load_spell_module(spell_id, revision_id, manifest)
	
	if module:
		_loaded_modules[key] = module
		print("[SpellRegistry] Successfully loaded spell module: ", spell_id, "/", revision_id)
		spell_loaded.emit(spell_id, revision_id)
	else:
		push_error("[SpellRegistry] Failed to load module for ", spell_id, "/", revision_id)
		spell_load_failed.emit(spell_id, revision_id, "Failed to load module")


# ============================================================================
# Spell Access
# ============================================================================

func get_spell_module(spell_id: String, revision_id: String = "") -> SpellModule:
	"""Get a loaded spell module. Returns null if not loaded."""
	if revision_id.is_empty():
		revision_id = get_active_revision(spell_id)
	
	if revision_id.is_empty():
		return null
	
	var key := "%s/%s" % [spell_id, revision_id]
	return _loaded_modules.get(key) as SpellModule


func get_manifest(spell_id: String, revision_id: String = "") -> Dictionary:
	"""Get the manifest for a spell revision."""
	if revision_id.is_empty():
		revision_id = get_active_revision(spell_id)
	
	if revision_id.is_empty():
		return {}
	
	var key := "%s/%s" % [spell_id, revision_id]
	
	var manifest: Dictionary = _manifests.get(key, {})
	if manifest.is_empty() and _cache:
		manifest = _cache.get_manifest(spell_id, revision_id)
		if not manifest.is_empty():
			_manifests[key] = manifest
	
	return manifest


func is_spell_loaded(spell_id: String, revision_id: String = "") -> bool:
	"""Check if a spell module is loaded."""
	if revision_id.is_empty():
		revision_id = get_active_revision(spell_id)
	
	if revision_id.is_empty():
		return false
	
	var key := "%s/%s" % [spell_id, revision_id]
	return _loaded_modules.has(key)


# ============================================================================
# Spell Instantiation
# ============================================================================

func create_spell_context(
	spell_id: String,
	revision_id: String,
	cast_event: Dictionary
) -> SpellContext:
	"""Create a SpellContext for a cast event."""
	var ctx := SpellContext.new()
	ctx.init_from_cast_event(cast_event)
	
	# Get manifest
	ctx.manifest = get_manifest(spell_id, revision_id)
	
	return ctx


# ============================================================================
# Cleanup
# ============================================================================

func unload_spell(spell_id: String, revision_id: String) -> void:
	"""Unload a spell module from memory."""
	var key := "%s/%s" % [spell_id, revision_id]
	_loaded_modules.erase(key)
	_manifests.erase(key)


func clear_all() -> void:
	"""Clear all loaded spells and registrations."""
	_active_revisions.clear()
	_loaded_modules.clear()
	_manifests.clear()
