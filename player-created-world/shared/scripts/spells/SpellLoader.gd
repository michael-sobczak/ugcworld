extends Node

## SpellLoader singleton - handles hot-loading of spell scripts and assets at runtime.
## 
## Hot-loading approach:
## Since Godot's load()/ResourceLoader doesn't work on user:// paths for scripts
## in export builds, we use GDScript.new() and set source_code directly.
## This allows loading arbitrary GDScript from any location at runtime.

signal asset_loaded(spell_id: String, revision_id: String, asset_path: String)
signal asset_load_failed(spell_id: String, revision_id: String, asset_path: String, error_msg: String)

## Reference to SpellCache
var _cache: Node = null

## Loaded script resources cache (to avoid recompiling)
## "spell_id/revision_id" -> GDScript resource
var _script_cache: Dictionary = {}

## Loaded asset resources cache
## "spell_id/revision_id/path" -> Resource
var _asset_cache: Dictionary = {}


func _ready() -> void:
	call_deferred("_init_references")


func _init_references() -> void:
	_cache = get_node_or_null("/root/SpellCache")


# ============================================================================
# Script Hot-Loading
# ============================================================================

func load_spell_module(spell_id: String, revision_id: String, manifest: Dictionary) -> SpellModule:
	"""
	Load a spell module from cache using hot-loading.
	Returns a new instance of the spell module, or null on failure.
	"""
	var key: String = "%s/%s" % [spell_id, revision_id]
	
	# Check script cache first
	if _script_cache.has(key):
		var cached_script: GDScript = _script_cache[key]
		return _instantiate_module(cached_script, spell_id, revision_id)
	
	# Get entrypoint from manifest
	var entrypoint: String = manifest.get("entrypoint", "code/spell.gd")
	
	if not _cache:
		push_error("[SpellLoader] SpellCache not available")
		return null
	
	# Read the script source code from cache
	var source_code: String = _cache.read_file_text(spell_id, revision_id, entrypoint)
	
	if source_code.is_empty():
		push_error("[SpellLoader] Failed to read script: ", entrypoint)
		return null
	
	# Create GDScript from source
	var script: GDScript = _compile_script(source_code, spell_id, revision_id)
	
	if not script:
		return null
	
	# Cache the compiled script
	_script_cache[key] = script
	
	# Instantiate and return
	return _instantiate_module(script, spell_id, revision_id)


func _compile_script(source_code: String, spell_id: String, revision_id: String) -> GDScript:
	"""Compile GDScript from source code string."""
	var script: GDScript = GDScript.new()
	script.source_code = source_code
	
	# Attempt to reload/compile the script
	var err: Error = script.reload()
	
	if err != OK:
		push_error("[SpellLoader] Failed to compile script for ", spell_id, "/", revision_id, ": ", err)
		return null
	
	print("[SpellLoader] Compiled script for ", spell_id, "/", revision_id)
	return script


func _instantiate_module(script: GDScript, spell_id: String, revision_id: String) -> SpellModule:
	"""Instantiate a SpellModule from a compiled GDScript."""
	var instance: Variant = script.new()
	
	if not instance:
		push_error("[SpellLoader] Failed to instantiate script for ", spell_id, "/", revision_id)
		return null
	
	# Verify it's a SpellModule (or at least has the required interface)
	if not (instance is SpellModule):
		# Check if it at least has on_cast method (duck typing fallback)
		if not instance.has_method("on_cast"):
			push_error("[SpellLoader] Script does not extend SpellModule or have on_cast: ", spell_id)
			return null
		
		# Wrap in a proxy if needed
		push_warning("[SpellLoader] Script doesn't extend SpellModule, using duck typing")
	
	return instance as SpellModule


# ============================================================================
# Asset Loading
# ============================================================================

func load_spell_assets(spell_id: String, revision_id: String, manifest: Dictionary) -> Dictionary:
	"""
	Load all assets for a spell revision.
	Returns a dictionary of relative_path -> Resource.
	"""
	var loaded_assets: Dictionary = {}
	
	var asset_list: Array = manifest.get("assets", [])
	
	for asset_info: Variant in asset_list:
		if not asset_info is Dictionary:
			continue
		
		var asset_path: String = (asset_info as Dictionary).get("path", "")
		if asset_path.is_empty():
			continue
		
		var resource: Resource = load_asset(spell_id, revision_id, asset_path)
		if resource:
			loaded_assets[asset_path] = resource
	
	return loaded_assets


func load_asset(spell_id: String, revision_id: String, relative_path: String) -> Resource:
	"""Load a single asset from cache."""
	var cache_key: String = "%s/%s/%s" % [spell_id, revision_id, relative_path]
	
	# Check cache
	if _asset_cache.has(cache_key):
		return _asset_cache[cache_key]
	
	if not _cache:
		push_error("[SpellLoader] SpellCache not available")
		return null
	
	# Determine asset type from extension
	var ext: String = relative_path.get_extension().to_lower()
	var resource: Resource = null
	
	match ext:
		"png", "jpg", "jpeg", "webp":
			resource = _load_image(spell_id, revision_id, relative_path)
		"wav", "ogg", "mp3":
			resource = _load_audio(spell_id, revision_id, relative_path, ext)
		"tscn", "scn":
			resource = _load_scene(spell_id, revision_id, relative_path)
		"tres", "res":
			resource = _load_resource_file(spell_id, revision_id, relative_path)
		"gltf", "glb":
			resource = _load_gltf(spell_id, revision_id, relative_path)
		_:
			push_warning("[SpellLoader] Unknown asset type: ", ext, " for ", relative_path)
	
	if resource:
		_asset_cache[cache_key] = resource
		asset_loaded.emit(spell_id, revision_id, relative_path)
	else:
		asset_load_failed.emit(spell_id, revision_id, relative_path, "Failed to load")
	
	return resource


func _load_image(spell_id: String, revision_id: String, relative_path: String) -> ImageTexture:
	"""Load an image file as ImageTexture."""
	var bytes: PackedByteArray = _cache.read_file_bytes(spell_id, revision_id, relative_path)
	
	if bytes.is_empty():
		return null
	
	var image: Image = Image.new()
	var ext: String = relative_path.get_extension().to_lower()
	var err: Error = OK
	
	match ext:
		"png":
			err = image.load_png_from_buffer(bytes)
		"jpg", "jpeg":
			err = image.load_jpg_from_buffer(bytes)
		"webp":
			err = image.load_webp_from_buffer(bytes)
		_:
			return null
	
	if err != OK:
		push_error("[SpellLoader] Failed to load image: ", relative_path)
		return null
	
	var texture: ImageTexture = ImageTexture.create_from_image(image)
	return texture


func _load_audio(spell_id: String, revision_id: String, relative_path: String, ext: String) -> AudioStream:
	"""Load an audio file as AudioStream."""
	var bytes: PackedByteArray = _cache.read_file_bytes(spell_id, revision_id, relative_path)
	
	if bytes.is_empty():
		return null
	
	# Note: Loading raw audio at runtime is limited in Godot
	# WAV files can be loaded, but OGG/MP3 need special handling
	match ext:
		"wav":
			# WAV loading from bytes not fully implemented
			push_warning("[SpellLoader] WAV loading from bytes not fully implemented")
			return null
		"ogg":
			# OGG loading requires the data to be in a specific format
			push_warning("[SpellLoader] OGG loading from bytes not supported")
			return null
		_:
			push_warning("[SpellLoader] Audio format not supported: ", ext)
			return null


func _load_scene(spell_id: String, revision_id: String, relative_path: String) -> PackedScene:
	"""
	Load a scene file.
	Note: Loading .tscn from user:// is limited in export builds.
	For full support, scenes should be in .pck format.
	"""
	# Get the actual file path
	var file_path: String = _cache.get_file_path(spell_id, revision_id, relative_path)
	
	# Try to load directly (works in editor, may fail in export)
	if ResourceLoader.exists(file_path):
		return load(file_path) as PackedScene
	
	push_warning("[SpellLoader] Scene loading from user:// not fully supported: ", relative_path)
	return null


func _load_resource_file(spell_id: String, revision_id: String, relative_path: String) -> Resource:
	"""Load a .tres or .res resource file."""
	var file_path: String = _cache.get_file_path(spell_id, revision_id, relative_path)
	
	if ResourceLoader.exists(file_path):
		return load(file_path)
	
	push_warning("[SpellLoader] Resource loading from user:// not fully supported: ", relative_path)
	return null


func _load_gltf(spell_id: String, revision_id: String, relative_path: String) -> Resource:
	"""Load a GLTF/GLB 3D model."""
	var bytes: PackedByteArray = _cache.read_file_bytes(spell_id, revision_id, relative_path)
	
	if bytes.is_empty():
		return null
	
	# GLTF loading at runtime
	var gltf_doc: GLTFDocument = GLTFDocument.new()
	var gltf_state: GLTFState = GLTFState.new()
	
	var err: Error = gltf_doc.append_from_buffer(bytes, "", gltf_state)
	
	if err != OK:
		push_error("[SpellLoader] Failed to parse GLTF: ", relative_path)
		return null
	
	var scene: Node = gltf_doc.generate_scene(gltf_state)
	# Can't return Node as Resource, so we return null for now
	# GLTF models would need different handling
	if scene:
		scene.queue_free()
	push_warning("[SpellLoader] GLTF loading returns Node, not Resource - use spawn_entity instead")
	return null


# ============================================================================
# Helper: Create WorldAPIAdapter with loaded assets
# ============================================================================

func create_world_adapter(spell_id: String, revision_id: String, manifest: Dictionary, scene_root: Node) -> WorldAPIAdapter:
	"""Create a WorldAPIAdapter with all spell assets loaded and registered."""
	var adapter: WorldAPIAdapter = WorldAPIAdapter.new(scene_root)
	
	# Set cache path for reference
	if _cache:
		var cache_path: String = _cache.get_cache_path(spell_id, revision_id)
		adapter.set_spell_cache_path(cache_path)
	
	# Load and register all assets
	var assets: Dictionary = load_spell_assets(spell_id, revision_id, manifest)
	for asset_path: String in assets:
		adapter.register_asset(asset_path, assets[asset_path])
	
	return adapter


# ============================================================================
# Cache Management
# ============================================================================

func clear_script_cache(spell_id: String = "", revision_id: String = "") -> void:
	"""Clear cached compiled scripts."""
	if spell_id.is_empty():
		_script_cache.clear()
	else:
		var key: String = "%s/%s" % [spell_id, revision_id]
		_script_cache.erase(key)


func clear_asset_cache(spell_id: String = "", revision_id: String = "") -> void:
	"""Clear cached assets."""
	if spell_id.is_empty():
		_asset_cache.clear()
	else:
		var prefix: String = "%s/%s/" % [spell_id, revision_id]
		var to_remove: Array = []
		for key: String in _asset_cache:
			if key.begins_with(prefix):
				to_remove.append(key)
		for key: String in to_remove:
			_asset_cache.erase(key)
