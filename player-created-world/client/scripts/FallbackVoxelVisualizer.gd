extends Node3D

## Fallback visualizer for testing when Voxel Tools addon is not installed.
## Creates simple CSGSphere3D nodes to show where ops would affect terrain.
## 
## This is NOT a real voxel system - just a visual debug aid.
## Replace with VoxelBackend + VoxelTerrain for actual gameplay.

@export var add_material: Material = null
@export var subtract_material: Material = null

var _sphere_count: int = 0


func _ready() -> void:
	# Create default materials if not set
	if add_material == null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.4, 0.6, 0.3)  # Earthy green
		mat.roughness = 0.8
		add_material = mat
	
	if subtract_material == null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.15, 0.1, 0.5)  # Dark transparent
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		subtract_material = mat
	
	# Connect to world ops
	var world_node = get_node_or_null("/root/World")
	if world_node:
		world_node.op_applied.connect(_on_op_applied)
		print("[FallbackVisualizer] Ready - using CSG spheres for visualization")
		print("[FallbackVisualizer] NOTE: Install Voxel Tools for proper terrain!")
	else:
		push_error("[FallbackVisualizer] World autoload not found!")


func _on_op_applied(op: Dictionary) -> void:
	var op_type: String = op.get("op", "")
	match op_type:
		"add_sphere":
			_visualize_add_sphere(op)
		"subtract_sphere":
			_visualize_subtract_sphere(op)


func _visualize_add_sphere(op: Dictionary) -> void:
	var center: Vector3 = op.get("center", Vector3.ZERO)
	var radius: float = op.get("radius", 8.0)
	
	var sphere := CSGSphere3D.new()
	sphere.name = "AddSphere_%d" % _sphere_count
	sphere.radius = radius
	sphere.radial_segments = 16
	sphere.rings = 8
	sphere.material = add_material
	sphere.operation = CSGShape3D.OPERATION_UNION
	
	add_child(sphere)
	sphere.global_position = center
	
	_sphere_count += 1
	print("[FallbackVisualizer] Added sphere at ", center, " r=", radius)


func _visualize_subtract_sphere(op: Dictionary) -> void:
	var center: Vector3 = op.get("center", Vector3.ZERO)
	var radius: float = op.get("radius", 6.0)
	
	# For subtraction, we show a transparent indicator
	# In real CSG we'd need OPERATION_SUBTRACTION but that requires proper hierarchy
	var sphere := CSGSphere3D.new()
	sphere.name = "SubSphere_%d" % _sphere_count
	sphere.radius = radius
	sphere.radial_segments = 12
	sphere.rings = 6
	sphere.material = subtract_material
	sphere.operation = CSGShape3D.OPERATION_UNION  # Can't really subtract without setup
	
	add_child(sphere)
	sphere.global_position = center
	
	_sphere_count += 1
	print("[FallbackVisualizer] Subtract sphere at ", center, " r=", radius)


func clear() -> void:
	for child in get_children():
		child.queue_free()
	_sphere_count = 0
