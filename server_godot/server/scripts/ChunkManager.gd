extends Node
## Server-side chunk manager for voxel terrain.
## Owns canonical chunk data with versioning for client sync.

## Chunk size in voxels
const CHUNK_SIZE := 32

## Loaded chunks: "cx_cy_cz" -> ChunkData
var _chunks: Dictionary = {}


class ChunkData:
	var chunk_id: Array = [0, 0, 0]  # [cx, cy, cz]
	var version: int = 0
	var voxels: PackedByteArray = PackedByteArray()
	var modified: bool = false
	
	func _init(cx: int, cy: int, cz: int) -> void:
		chunk_id = [cx, cy, cz]
		version = 0
		# Initialize with empty voxels (all air)
		voxels.resize(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
		voxels.fill(0)
	
	func get_voxel(x: int, y: int, z: int) -> int:
		if x < 0 or x >= CHUNK_SIZE or y < 0 or y >= CHUNK_SIZE or z < 0 or z >= CHUNK_SIZE:
			return 0
		var idx := x + y * CHUNK_SIZE + z * CHUNK_SIZE * CHUNK_SIZE
		return voxels[idx]
	
	func set_voxel(x: int, y: int, z: int, value: int) -> void:
		if x < 0 or x >= CHUNK_SIZE or y < 0 or y >= CHUNK_SIZE or z < 0 or z >= CHUNK_SIZE:
			return
		var idx := x + y * CHUNK_SIZE + z * CHUNK_SIZE * CHUNK_SIZE
		voxels[idx] = value
		modified = true


func _ready() -> void:
	print("[ChunkManager] Initialized with chunk size %d" % CHUNK_SIZE)


func _get_chunk_key(cx: int, cy: int, cz: int) -> String:
	return "%d_%d_%d" % [cx, cy, cz]


func get_or_create_chunk(cx: int, cy: int, cz: int) -> ChunkData:
	"""Get existing chunk or create new one."""
	var key := _get_chunk_key(cx, cy, cz)
	if not _chunks.has(key):
		_chunks[key] = ChunkData.new(cx, cy, cz)
	return _chunks[key]


func get_chunk(cx: int, cy: int, cz: int) -> ChunkData:
	"""Get chunk if it exists."""
	var key := _get_chunk_key(cx, cy, cz)
	return _chunks.get(key)


func world_to_chunk(world_pos: Vector3) -> Array:
	"""Convert world position to chunk coordinates."""
	var cx := int(floor(world_pos.x / CHUNK_SIZE))
	var cy := int(floor(world_pos.y / CHUNK_SIZE))
	var cz := int(floor(world_pos.z / CHUNK_SIZE))
	return [cx, cy, cz]


func world_to_local(world_pos: Vector3, chunk_coords: Array) -> Vector3i:
	"""Convert world position to local chunk position."""
	var lx: int = int(world_pos.x) - chunk_coords[0] * CHUNK_SIZE
	var ly: int = int(world_pos.y) - chunk_coords[1] * CHUNK_SIZE
	var lz: int = int(world_pos.z) - chunk_coords[2] * CHUNK_SIZE
	return Vector3i(lx, ly, lz)


func apply_terraform(op_type: int, center: Vector3, radius: float, material_id: int) -> Array:
	"""
	Apply a terraform operation and return affected chunks.
	Returns: Array of {chunk_id: [cx,cy,cz], new_version: int}
	"""
	var affected: Dictionary = {}  # chunk_key -> ChunkData
	
	# Calculate bounding box
	var min_pos := center - Vector3.ONE * radius
	var max_pos := center + Vector3.ONE * radius
	
	var min_chunk := world_to_chunk(min_pos)
	var max_chunk := world_to_chunk(max_pos)
	
	# Iterate through affected voxels
	for x in range(int(min_pos.x), int(max_pos.x) + 1):
		for y in range(int(min_pos.y), int(max_pos.y) + 1):
			for z in range(int(min_pos.z), int(max_pos.z) + 1):
				var world_pos := Vector3(x, y, z)
				var dist := world_pos.distance_to(center)
				
				if dist <= radius:
					var chunk_coords := world_to_chunk(world_pos)
					var chunk := get_or_create_chunk(chunk_coords[0], chunk_coords[1], chunk_coords[2])
					var local := world_to_local(world_pos, chunk_coords)
					
					var chunk_key := _get_chunk_key(chunk_coords[0], chunk_coords[1], chunk_coords[2])
					affected[chunk_key] = chunk
					
					match op_type:
						Protocol.TerraformOp.SPHERE_ADD:
							chunk.set_voxel(local.x, local.y, local.z, material_id)
						Protocol.TerraformOp.SPHERE_SUB:
							chunk.set_voxel(local.x, local.y, local.z, 0)
						Protocol.TerraformOp.PAINT:
							if chunk.get_voxel(local.x, local.y, local.z) != 0:
								chunk.set_voxel(local.x, local.y, local.z, material_id)
	
	# Increment versions and build result
	var result: Array = []
	for chunk_key in affected.keys():
		var chunk: ChunkData = affected[chunk_key]
		chunk.version += 1
		result.append({
			"chunk_id": chunk.chunk_id,
			"new_version": chunk.version,
		})
	
	print("[ChunkManager] Terraform affected %d chunks" % result.size())
	return result


func get_chunk_data(chunk_id: Array, last_known_version: int = 0) -> Dictionary:
	"""Get chunk data if newer than last_known_version."""
	if chunk_id.size() < 3:
		return {}
	
	var chunk := get_chunk(chunk_id[0], chunk_id[1], chunk_id[2])
	if chunk == null:
		return {}
	
	if chunk.version <= last_known_version:
		return {}  # Client already has latest
	
	# Compress chunk data
	var compressed := compress_chunk(chunk)
	
	return Protocol.build_chunk_data(chunk_id, chunk.version, compressed, true)


func compress_chunk(chunk: ChunkData) -> PackedByteArray:
	"""Compress chunk voxel data."""
	# Simple RLE compression for sparse chunks
	return chunk.voxels.compress(FileAccess.COMPRESSION_GZIP)


func decompress_chunk(data: PackedByteArray) -> PackedByteArray:
	"""Decompress chunk voxel data."""
	return data.decompress(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE, FileAccess.COMPRESSION_GZIP)


func save_chunks() -> Array:
	"""Save all modified chunks for persistence."""
	var result: Array = []
	
	for chunk_key in _chunks.keys():
		var chunk: ChunkData = _chunks[chunk_key]
		if chunk.modified:
			result.append({
				"chunk_id": chunk.chunk_id,
				"version": chunk.version,
				"data": Marshalls.raw_to_base64(compress_chunk(chunk)),
			})
			chunk.modified = false
	
	print("[ChunkManager] Saved %d chunks" % result.size())
	return result


func load_chunks(chunks_data: Array) -> void:
	"""Load chunks from persistence."""
	for chunk_data in chunks_data:
		var chunk_id: Array = chunk_data.get("chunk_id", [0, 0, 0])
		var version: int = chunk_data.get("version", 0)
		var data_b64: String = chunk_data.get("data", "")
		
		if data_b64.is_empty():
			continue
		
		var compressed := Marshalls.base64_to_raw(data_b64)
		var voxels := decompress_chunk(compressed)
		
		var chunk := get_or_create_chunk(chunk_id[0], chunk_id[1], chunk_id[2])
		chunk.version = version
		chunk.voxels = voxels
		chunk.modified = false
	
	print("[ChunkManager] Loaded %d chunks" % chunks_data.size())


func get_voxel_at(world_pos: Vector3) -> int:
	"""Get voxel value at world position."""
	var chunk_coords := world_to_chunk(world_pos)
	var chunk := get_chunk(chunk_coords[0], chunk_coords[1], chunk_coords[2])
	if chunk == null:
		return 0
	
	var local := world_to_local(world_pos, chunk_coords)
	return chunk.get_voxel(local.x, local.y, local.z)


func raycast_voxels(origin: Vector3, direction: Vector3, max_distance: float = 100.0) -> Dictionary:
	"""
	Raycast against voxel terrain.
	Returns: {hit: bool, position: Vector3, normal: Vector3, voxel_value: int}
	"""
	var step := 0.5
	var distance := 0.0
	var pos := origin
	var prev_pos := origin
	
	while distance < max_distance:
		var voxel := get_voxel_at(pos)
		if voxel != 0:
			# Hit solid voxel
			var normal := (prev_pos - pos).normalized()
			return {
				"hit": true,
				"position": pos,
				"normal": normal,
				"voxel_value": voxel,
			}
		
		prev_pos = pos
		pos += direction * step
		distance += step
	
	return {"hit": false}
