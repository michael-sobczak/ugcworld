extends Node

## SpellCache singleton - manages local caching and downloading of spell packages.
## Handles filesystem operations and network requests for spell content.

signal download_started(spell_id: String, revision_id: String)
signal download_progress(spell_id: String, revision_id: String, progress: float)
signal download_complete(spell_id: String, revision_id: String)
signal download_failed(spell_id: String, revision_id: String, error: String)

## Base cache directory (user://spell_cache/)
const CACHE_BASE := "user://spell_cache"

## Track pending downloads to avoid duplicates
var _pending_downloads: Dictionary = {}  # "spell_id/revision_id" -> bool

## Reference to Net singleton for downloading
var _net: Node = null


func _ready() -> void:
	_ensure_cache_dir()
	_net = get_node_or_null("/root/Net")


# ============================================================================
# Cache Directory Management
# ============================================================================

func _ensure_cache_dir() -> void:
	"""Ensure the cache directory exists."""
	DirAccess.make_dir_recursive_absolute(CACHE_BASE)


func get_cache_path(spell_id: String, revision_id: String) -> String:
	"""Get the full cache path for a revision."""
	return CACHE_BASE.path_join(spell_id).path_join(revision_id)


func get_file_path(spell_id: String, revision_id: String, relative_path: String) -> String:
	"""Get the full path to a cached file."""
	return get_cache_path(spell_id, revision_id).path_join(relative_path)


func revision_cached(spell_id: String, revision_id: String) -> bool:
	"""Check if a revision is fully cached (manifest + all files)."""
	var manifest_path: String = get_file_path(spell_id, revision_id, "manifest.json")
	if not FileAccess.file_exists(manifest_path):
		return false
	
	# Load manifest and check all files exist
	var manifest: Dictionary = get_manifest(spell_id, revision_id)
	if manifest.is_empty():
		return false
	
	# Check code files
	var code_files: Array = manifest.get("code", [])
	for file_info: Variant in code_files:
		if file_info is Dictionary:
			var path: String = (file_info as Dictionary).get("path", "")
			if not path.is_empty() and not file_cached(spell_id, revision_id, path):
				return false
	
	# Check asset files
	var asset_files: Array = manifest.get("assets", [])
	for file_info: Variant in asset_files:
		if file_info is Dictionary:
			var path: String = (file_info as Dictionary).get("path", "")
			if not path.is_empty() and not file_cached(spell_id, revision_id, path):
				return false
	
	return true


func file_cached(spell_id: String, revision_id: String, relative_path: String) -> bool:
	"""Check if a specific file is cached."""
	var file_path := get_file_path(spell_id, revision_id, relative_path)
	return FileAccess.file_exists(file_path)


# ============================================================================
# Manifest Operations
# ============================================================================

func get_manifest(spell_id: String, revision_id: String) -> Dictionary:
	"""Load manifest from cache."""
	var manifest_path := get_file_path(spell_id, revision_id, "manifest.json")
	
	if not FileAccess.file_exists(manifest_path):
		return {}
	
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if not file:
		return {}
	
	var content := file.get_as_text()
	file.close()
	
	var json := JSON.new()
	if json.parse(content) != OK:
		return {}
	
	return json.data as Dictionary


func save_manifest(spell_id: String, revision_id: String, manifest: Dictionary) -> bool:
	"""Save manifest to cache."""
	var cache_dir := get_cache_path(spell_id, revision_id)
	DirAccess.make_dir_recursive_absolute(cache_dir)
	
	var manifest_path := get_file_path(spell_id, revision_id, "manifest.json")
	var file := FileAccess.open(manifest_path, FileAccess.WRITE)
	
	if not file:
		push_error("[SpellCache] Failed to write manifest: ", manifest_path)
		return false
	
	file.store_string(JSON.stringify(manifest, "\t"))
	file.close()
	return true


# ============================================================================
# File Operations
# ============================================================================

func read_file_text(spell_id: String, revision_id: String, relative_path: String) -> String:
	"""Read a text file from cache."""
	var file_path := get_file_path(spell_id, revision_id, relative_path)
	
	if not FileAccess.file_exists(file_path):
		return ""
	
	var file := FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return ""
	
	var content := file.get_as_text()
	file.close()
	return content


func read_file_bytes(spell_id: String, revision_id: String, relative_path: String) -> PackedByteArray:
	"""Read a binary file from cache."""
	var file_path := get_file_path(spell_id, revision_id, relative_path)
	
	if not FileAccess.file_exists(file_path):
		return PackedByteArray()
	
	var file := FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return PackedByteArray()
	
	var content := file.get_buffer(file.get_length())
	file.close()
	return content


func save_file(spell_id: String, revision_id: String, relative_path: String, content: PackedByteArray) -> bool:
	"""Save a file to cache."""
	var file_path := get_file_path(spell_id, revision_id, relative_path)
	
	# Ensure parent directory exists
	var parent_dir := file_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(parent_dir)
	
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if not file:
		push_error("[SpellCache] Failed to write file: ", file_path)
		return false
	
	file.store_buffer(content)
	file.close()
	return true


func save_file_text(spell_id: String, revision_id: String, relative_path: String, content: String) -> bool:
	"""Save a text file to cache."""
	return save_file(spell_id, revision_id, relative_path, content.to_utf8_buffer())


# ============================================================================
# Download from Server
# ============================================================================

func ensure_revision_cached(spell_id: String, revision_id: String, manifest: Dictionary = {}) -> void:
	"""
	Ensure a revision is fully cached, downloading if necessary.
	Emits download_complete or download_failed when done.
	"""
	var key := "%s/%s" % [spell_id, revision_id]
	
	# Already downloading?
	if _pending_downloads.get(key, false):
		return
	
	# Already cached?
	if revision_cached(spell_id, revision_id):
		download_complete.emit(spell_id, revision_id)
		return
	
	# Start download
	_pending_downloads[key] = true
	download_started.emit(spell_id, revision_id)
	
	# If manifest provided, use it; otherwise request it
	if manifest.is_empty():
		_request_manifest(spell_id, revision_id)
	else:
		_download_revision_files(spell_id, revision_id, manifest)


func _request_manifest(spell_id: String, revision_id: String) -> void:
	"""Request manifest from server via Net."""
	if not _net:
		_download_error(spell_id, revision_id, "Net not available")
		return
	
	# The SpellNet singleton handles this - we'll wire it up there
	# For now, emit error
	_download_error(spell_id, revision_id, "Manifest request not implemented via SpellNet")


func _download_revision_files(spell_id: String, revision_id: String, manifest: Dictionary) -> void:
	"""Download all files listed in the manifest."""
	# Save manifest first
	save_manifest(spell_id, revision_id, manifest)
	
	# Collect all files to download
	var files_to_download: Array = []
	
	# Code files
	var code_files: Array = manifest.get("code", [])
	for file_info: Variant in code_files:
		if file_info is Dictionary:
			var path: String = (file_info as Dictionary).get("path", "")
			if not path.is_empty():
				files_to_download.append(path)
	
	# Asset files
	var asset_files: Array = manifest.get("assets", [])
	for file_info: Variant in asset_files:
		if file_info is Dictionary:
			var path: String = (file_info as Dictionary).get("path", "")
			if not path.is_empty():
				files_to_download.append(path)
	
	# Filter out already cached files
	var files_needed: Array = []
	for file_path: String in files_to_download:
		if not file_cached(spell_id, revision_id, file_path):
			files_needed.append(file_path)
	
	if files_needed.is_empty():
		# All files already cached
		var key: String = "%s/%s" % [spell_id, revision_id]
		_pending_downloads.erase(key)
		download_complete.emit(spell_id, revision_id)
		return
	
	print("[SpellCache] Need to download ", files_needed.size(), " files for ", spell_id, "/", revision_id)
	
	# Store pending download state
	var key: String = "%s/%s" % [spell_id, revision_id]
	_pending_downloads[key] = {
		"files_needed": files_needed,
		"files_received": 0,
		"manifest": manifest
	}
	
	# Request each file via SpellNet
	var spell_net: Node = get_node_or_null("/root/SpellNet")
	if spell_net:
		for file_path: String in files_needed:
			print("[SpellCache] Requesting file: ", file_path)
			spell_net.request_file(spell_id, revision_id, file_path)
	else:
		_download_error(spell_id, revision_id, "SpellNet not available")


func on_file_received(spell_id: String, revision_id: String, relative_path: String, content: PackedByteArray) -> void:
	"""Called when a file is received from the server."""
	print("[SpellCache] File received: ", relative_path, " (", content.size(), " bytes)")
	save_file(spell_id, revision_id, relative_path, content)
	
	var key: String = "%s/%s" % [spell_id, revision_id]
	var state: Variant = _pending_downloads.get(key)
	
	if state is Dictionary:
		var state_dict: Dictionary = state as Dictionary
		state_dict["files_received"] = state_dict.get("files_received", 0) + 1
		var files_needed: Array = state_dict.get("files_needed", [])
		var total: int = files_needed.size()
		var received: int = state_dict["files_received"]
		
		print("[SpellCache] Download progress: ", received, "/", total)
		download_progress.emit(spell_id, revision_id, float(received) / float(total))
		
		if received >= total:
			print("[SpellCache] All files downloaded for ", spell_id, "/", revision_id)
			_pending_downloads.erase(key)
			download_complete.emit(spell_id, revision_id)
	else:
		print("[SpellCache] Warning: Received file but no pending download state for ", key)


func _download_error(spell_id: String, revision_id: String, error: String) -> void:
	"""Handle download error."""
	var key := "%s/%s" % [spell_id, revision_id]
	_pending_downloads.erase(key)
	push_error("[SpellCache] Download failed: ", error)
	download_failed.emit(spell_id, revision_id, error)


# ============================================================================
# Cache Management
# ============================================================================

func list_cached_spells() -> Array[String]:
	"""List all spell IDs with cached revisions."""
	var spells: Array[String] = []
	
	var dir := DirAccess.open(CACHE_BASE)
	if not dir:
		return spells
	
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and not name.begins_with("."):
			spells.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	
	return spells


func list_cached_revisions(spell_id: String) -> Array[String]:
	"""List all cached revision IDs for a spell."""
	var revisions: Array[String] = []
	
	var spell_dir := CACHE_BASE.path_join(spell_id)
	var dir := DirAccess.open(spell_dir)
	if not dir:
		return revisions
	
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and not name.begins_with("."):
			revisions.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	
	return revisions


func clear_revision_cache(spell_id: String, revision_id: String) -> bool:
	"""Delete a cached revision."""
	var cache_path := get_cache_path(spell_id, revision_id)
	
	var dir := DirAccess.open(cache_path)
	if not dir:
		return false
	
	# Recursively delete
	_delete_dir_recursive(cache_path)
	return true


func _delete_dir_recursive(path: String) -> void:
	"""Recursively delete a directory."""
	var dir := DirAccess.open(path)
	if not dir:
		return
	
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var full_path := path.path_join(name)
			if dir.current_is_dir():
				_delete_dir_recursive(full_path)
			else:
				dir.remove(name)
		name = dir.get_next()
	dir.list_dir_end()
	
	# Remove the now-empty directory
	DirAccess.remove_absolute(path)
