extends Node

## Voxel terrain backend that applies world ops to the visual terrain.
## This script bridges the server-authoritative World.gd ops to actual voxel edits.
##
## For this demo, we use CSG fallback visualization which works reliably.
## Full VoxelTerrain integration requires additional setup (see docs/VOXELS.md).

## The VoxelTerrain or VoxelLodTerrain node to edit (for future use)
@export var voxel_terrain: Node3D = null

## Force fallback mode (CSG visualization) - enable for reliable demo
@export var force_fallback: bool = true

## Material ID for "air" (empty voxel)
const VOXEL_AIR := 0
## Default material ID for solid terrain
const VOXEL_SOLID := 1

## Whether this backend is active (disabled on headless server)
var _active := true

## Whether we're using the fallback visualizer
var _using_fallback := false

## Fallback visualizer (CSG spheres for testing)
var _fallback_visualizer: Node3D = null

## Material for fallback add spheres
var _fallback_add_material: StandardMaterial3D = null
## Material for fallback subtract spheres  
var _fallback_sub_material: StandardMaterial3D = null
## Counter for fallback sphere names
var _fallback_sphere_count: int = 0


func _ready() -> void:
	# Skip voxel rendering on headless server
	if _is_headless():
		_active = false
		print("[VoxelBackend] Running headless - voxel visuals disabled")
		return
	
	# Use fallback mode for reliable demo
	if force_fallback:
		_setup_fallback_visualizer()
	else:
		# Try to find and use VoxelTerrain
		if voxel_terrain == null:
			voxel_terrain = _find_voxel_terrain()
		
		if voxel_terrain == null:
			_setup_fallback_visualizer()
		else:
			print("[VoxelBackend] Found VoxelTerrain - but using fallback for demo reliability")
			_setup_fallback_visualizer()
	
	# Connect to the world op signal
	var world_node = get_node_or_null("/root/World")
	if world_node:
		world_node.op_applied.connect(_on_op_applied)
		print("[VoxelBackend] Ready. Using CSG visualization for terrain.")
	else:
		push_error("[VoxelBackend] World autoload not found!")
		_active = false


func _setup_fallback_visualizer() -> void:
	_using_fallback = true
	_active = true
	
	_fallback_visualizer = Node3D.new()
	_fallback_visualizer.name = "TerrainVisualizer"
	add_child(_fallback_visualizer)
	
	# Create materials
	_fallback_add_material = StandardMaterial3D.new()
	_fallback_add_material.albedo_color = Color(0.45, 0.55, 0.35)  # Earthy green
	_fallback_add_material.roughness = 0.85
	
	_fallback_sub_material = StandardMaterial3D.new()
	_fallback_sub_material.albedo_color = Color(0.3, 0.2, 0.15, 0.6)
	_fallback_sub_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA


func _is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


func _find_voxel_terrain() -> Node3D:
	var parent := get_parent()
	if parent == null:
		return null
	
	for child in parent.get_children():
		if _is_voxel_terrain(child):
			return child
	
	return null


func _is_voxel_terrain(node: Node) -> bool:
	var class_name_str := node.get_class()
	return class_name_str in ["VoxelTerrain", "VoxelLodTerrain"]


func _on_op_applied(op: Dictionary) -> void:
	if not _active:
		return
	
	var op_type: String = op.get("op", "")
	match op_type:
		"add_sphere":
			_apply_add_sphere(op)
		"subtract_sphere":
			_apply_subtract_sphere(op)
		_:
			print("[VoxelBackend] Unknown op type: ", op_type)


func _apply_add_sphere(op: Dictionary) -> void:
	var center: Vector3 = op.get("center", Vector3.ZERO)
	var radius: float = op.get("radius", 8.0)
	var _material_id: int = op.get("material_id", VOXEL_SOLID)
	
	_create_terrain_sphere(center, radius, true)
	print("[VoxelBackend] add_sphere at ", center, " r=", radius)


func _apply_subtract_sphere(op: Dictionary) -> void:
	var center: Vector3 = op.get("center", Vector3.ZERO)
	var radius: float = op.get("radius", 6.0)
	
	_create_terrain_sphere(center, radius, false)
	print("[VoxelBackend] subtract_sphere at ", center, " r=", radius)


func _create_terrain_sphere(center: Vector3, radius: float, is_add: bool) -> void:
	if _fallback_visualizer == null:
		return
	
	var sphere := CSGSphere3D.new()
	sphere.name = "Terrain_%d" % _fallback_sphere_count
	sphere.radius = radius
	sphere.radial_segments = 24
	sphere.rings = 12
	
	if is_add:
		sphere.material = _fallback_add_material
		sphere.operation = CSGShape3D.OPERATION_UNION
	else:
		sphere.material = _fallback_sub_material
		# For subtraction to work properly, we'd need a CSG hierarchy
		# For now just show as semi-transparent
		sphere.operation = CSGShape3D.OPERATION_UNION
	
	_fallback_visualizer.add_child(sphere)
	sphere.global_position = center
	_fallback_sphere_count += 1


## Public API

func add_sphere(center: Vector3, radius: float, material_id: int = VOXEL_SOLID) -> void:
	_apply_add_sphere({
		"op": "add_sphere",
		"center": center,
		"radius": radius,
		"material_id": material_id
	})


func subtract_sphere(center: Vector3, radius: float) -> void:
	_apply_subtract_sphere({
		"op": "subtract_sphere",
		"center": center,
		"radius": radius
	})


func replay_ops(ops: Array) -> void:
	if not _active:
		return
	
	print("[VoxelBackend] Replaying ", ops.size(), " ops for sync...")
	for op in ops:
		_on_op_applied(op)
	print("[VoxelBackend] Replay complete.")


func is_using_fallback() -> bool:
	return _using_fallback


func is_active() -> bool:
	return _active


func clear_terrain() -> void:
	if _fallback_visualizer:
		for child in _fallback_visualizer.get_children():
			child.queue_free()
		_fallback_sphere_count = 0
