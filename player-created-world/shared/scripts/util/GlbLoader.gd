class_name GlbLoader
extends RefCounted

static func load_glb(path: String) -> Node:
	if path.is_empty():
		return null
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("[GlbLoader] Failed to read GLB: " + path)
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_buffer(bytes, "", state)
	if err != OK:
		push_error("[GlbLoader] Failed to parse GLB: " + path)
		return null
	var scene := doc.generate_scene(state)
	return scene
