## ModelExtractor - Handles extraction of GGUF models from PCK to filesystem
##
## llama.cpp requires filesystem paths, not Godot virtual paths.
## This class extracts embedded models to user://models_cache/ on first use.
extends RefCounted
class_name LLMModelExtractor

const CACHE_DIR = "user://models_cache"
const TEMP_SUFFIX = ".tmp"
const HASH_FILE_SUFFIX = ".sha256"
const CHUNK_SIZE = 1048576  # 1MB chunks for extraction

## Signal emitted during extraction with progress (0.0 to 1.0)
signal extraction_progress(model_id: String, progress: float)


func _init() -> void:
	# Ensure cache directory exists
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(CACHE_DIR)
	)


## Ensure a model is extracted and return the filesystem path
## Returns: { success: bool, path: String, error: String }
func ensure_extracted(model_info: Dictionary) -> Dictionary:
	var model_id = model_info.get("id", "")
	var pck_path = model_info.get("file_path_in_pck", "")
	var expected_hash = model_info.get("sha256", "")
	var size_bytes = model_info.get("size_bytes", 0)
	
	if pck_path.is_empty():
		return {"success": false, "path": "", "error": "No file_path_in_pck specified"}
	
	# Determine cache path
	var filename = pck_path.get_file()
	var cache_path = CACHE_DIR.path_join(filename)
	var absolute_path = ProjectSettings.globalize_path(cache_path)
	var hash_path = cache_path + HASH_FILE_SUFFIX
	
	print("[LocalLLM] Checking cache for: %s" % model_id)
	print("[LocalLLM] Cache path: %s" % absolute_path)
	
	# Check if already extracted and valid
	if FileAccess.file_exists(cache_path):
		var cached_hash = _read_cached_hash(hash_path)
		
		if not expected_hash.is_empty() and cached_hash == expected_hash:
			print("[LocalLLM] Model already extracted and hash matches: %s" % model_id)
			return {"success": true, "path": absolute_path, "error": ""}
		
		# If no expected hash, check file size as fallback
		if expected_hash.is_empty() and size_bytes > 0:
			var file = FileAccess.open(cache_path, FileAccess.READ)
			if file != null:
				var actual_size = file.get_length()
				file.close()
				if actual_size == size_bytes:
					print("[LocalLLM] Model already extracted, size matches: %s" % model_id)
					return {"success": true, "path": absolute_path, "error": ""}
		
		print("[LocalLLM] Cached model hash mismatch or incomplete, re-extracting")
	
	# Check if source exists
	if not FileAccess.file_exists(pck_path):
		return {"success": false, "path": "", "error": "Model file not found in PCK: %s" % pck_path}
	
	# Extract the model
	print("[LocalLLM] Extracting model: %s -> %s" % [pck_path, absolute_path])
	var result = await _extract_model(pck_path, cache_path, model_id)
	
	if not result.success:
		return result
	
	# Verify hash if provided
	if not expected_hash.is_empty():
		print("[LocalLLM] Verifying SHA256...")
		var actual_hash = await _compute_file_hash(cache_path)
		
		if actual_hash != expected_hash:
			# Delete the bad file
			DirAccess.remove_absolute(absolute_path)
			return {
				"success": false, 
				"path": "", 
				"error": "Hash mismatch! Expected: %s, Got: %s" % [expected_hash, actual_hash]
			}
		
		# Save hash for future validation
		_write_cached_hash(hash_path, actual_hash)
		print("[LocalLLM] Hash verified successfully")
	
	return {"success": true, "path": absolute_path, "error": ""}


## Extract a model file with progress reporting
func _extract_model(src_path: String, dst_path: String, model_id: String) -> Dictionary:
	var temp_path = dst_path + TEMP_SUFFIX
	
	# Open source
	var src = FileAccess.open(src_path, FileAccess.READ)
	if src == null:
		return {"success": false, "error": "Failed to open source: %s" % error_string(FileAccess.get_open_error())}
	
	var total_size = src.get_length()
	
	# Open temp destination
	var dst = FileAccess.open(temp_path, FileAccess.WRITE)
	if dst == null:
		src.close()
		return {"success": false, "error": "Failed to create temp file: %s" % error_string(FileAccess.get_open_error())}
	
	# Copy in chunks
	var bytes_copied = 0
	while not src.eof_reached():
		var chunk = src.get_buffer(CHUNK_SIZE)
		if chunk.size() > 0:
			dst.store_buffer(chunk)
			bytes_copied += chunk.size()
			
			var progress = float(bytes_copied) / float(total_size)
			extraction_progress.emit(model_id, progress)
			
			# Yield to prevent blocking
			if Engine.is_in_physics_frame():
				await Engine.get_main_loop().process_frame
	
	src.close()
	dst.close()
	
	# Atomic rename
	var absolute_temp = ProjectSettings.globalize_path(temp_path)
	var absolute_dst = ProjectSettings.globalize_path(dst_path)
	
	# Remove existing if present
	if FileAccess.file_exists(dst_path):
		DirAccess.remove_absolute(absolute_dst)
	
	# Rename temp to final
	var err = DirAccess.rename_absolute(absolute_temp, absolute_dst)
	if err != OK:
		DirAccess.remove_absolute(absolute_temp)
		return {"success": false, "error": "Failed to rename temp file: %s" % error_string(err)}
	
	print("[LocalLLM] Extraction complete: %.2f MB" % (bytes_copied / 1048576.0))
	return {"success": true}


## Compute SHA256 hash of a file
func _compute_file_hash(path: String) -> String:
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	
	while not file.eof_reached():
		var chunk = file.get_buffer(CHUNK_SIZE)
		if chunk.size() > 0:
			ctx.update(chunk)
		
		# Yield to prevent blocking on large files
		if Engine.is_in_physics_frame():
			await Engine.get_main_loop().process_frame
	
	file.close()
	
	var hash_bytes = ctx.finish()
	return hash_bytes.hex_encode()


## Read cached hash from file
func _read_cached_hash(hash_path: String) -> String:
	if not FileAccess.file_exists(hash_path):
		return ""
	
	var file = FileAccess.open(hash_path, FileAccess.READ)
	if file == null:
		return ""
	
	var hash_str = file.get_line().strip_edges()
	file.close()
	return hash_str


## Write hash to cache file
func _write_cached_hash(hash_path: String, hash_value: String) -> void:
	var file = FileAccess.open(hash_path, FileAccess.WRITE)
	if file != null:
		file.store_line(hash_value)
		file.close()


## Clear the model cache
func clear_cache() -> void:
	var dir = DirAccess.open(CACHE_DIR)
	if dir == null:
		return
	
	dir.list_dir_begin()
	var filename = dir.get_next()
	while not filename.is_empty():
		if not dir.current_is_dir():
			var path = CACHE_DIR.path_join(filename)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		filename = dir.get_next()
	dir.list_dir_end()
	
	print("[LocalLLM] Cache cleared")


## Get cache size in bytes
func get_cache_size() -> int:
	var total = 0
	var dir = DirAccess.open(CACHE_DIR)
	if dir == null:
		return 0
	
	dir.list_dir_begin()
	var filename = dir.get_next()
	while not filename.is_empty():
		if not dir.current_is_dir() and not filename.ends_with(HASH_FILE_SUFFIX):
			var path = CACHE_DIR.path_join(filename)
			var file = FileAccess.open(path, FileAccess.READ)
			if file != null:
				total += file.get_length()
				file.close()
		filename = dir.get_next()
	dir.list_dir_end()
	
	return total
