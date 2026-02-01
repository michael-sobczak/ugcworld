@tool
extends EditorScript

## Editor script to set up VoxelTerrain in Main.tscn
## 
## How to use:
## 1. Install Voxel Tools addon (see docs/VOXELS.md)
## 2. Open this script in the Godot editor
## 3. Go to File > Run (or press Ctrl+Shift+X)
##
## This will add a properly configured VoxelTerrain to your Main scene.

func _run() -> void:
	print("=== VoxelTerrain Setup Script ===")
	
	# Check if VoxelTerrain class exists
	if not ClassDB.class_exists("VoxelTerrain"):
		push_error("VoxelTerrain class not found!")
		push_error("Please install Voxel Tools addon first. See docs/VOXELS.md")
		return
	
	# Load the main scene
	var main_scene = load("res://client/scenes/Main.tscn")
	if main_scene == null:
		push_error("Could not load Main.tscn")
		return
	
	var main_instance = main_scene.instantiate()
	
	# Find VoxelWorld node
	var voxel_world = main_instance.get_node_or_null("VoxelWorld")
	if voxel_world == null:
		push_error("VoxelWorld node not found in Main.tscn")
		main_instance.queue_free()
		return
	
	# Check if VoxelTerrain already exists
	var existing_terrain = null
	for child in voxel_world.get_children():
		if child.get_class() == "VoxelTerrain":
			existing_terrain = child
			break
	
	if existing_terrain:
		print("VoxelTerrain already exists in scene. Skipping creation.")
		main_instance.queue_free()
		return
	
	# Create VoxelTerrain
	var terrain = ClassDB.instantiate("VoxelTerrain")
	terrain.name = "VoxelTerrain"
	
	# Create a flat generator (starts empty - below the world)
	if ClassDB.class_exists("VoxelGeneratorFlat"):
		var generator = ClassDB.instantiate("VoxelGeneratorFlat")
		# Set height very low so terrain starts "empty"
		if generator.has_method("set_height"):
			generator.set_height(-1000.0)
		elif "height" in generator:
			generator.height = -1000.0
		terrain.generator = generator
		print("Created VoxelGeneratorFlat with height = -1000 (empty world)")
	
	# Create a blocky mesher for cube-style voxels
	if ClassDB.class_exists("VoxelMesherBlocky"):
		var mesher = ClassDB.instantiate("VoxelMesherBlocky")
		terrain.mesher = mesher
		print("Created VoxelMesherBlocky")
	elif ClassDB.class_exists("VoxelMesherCubes"):
		var mesher = ClassDB.instantiate("VoxelMesherCubes")
		terrain.mesher = mesher
		print("Created VoxelMesherCubes")
	
	# Configure terrain bounds
	# VoxelTerrain uses a bounds system for the editable area
	if terrain.has_method("set_bounds"):
		var bounds = AABB(Vector3(-512, -128, -512), Vector3(1024, 256, 1024))
		terrain.set_bounds(bounds)
	
	# Add terrain to VoxelWorld (before VoxelBackend so backend finds it)
	voxel_world.add_child(terrain)
	terrain.owner = main_instance
	
	# Move VoxelBackend to be after VoxelTerrain
	var backend = voxel_world.get_node_or_null("VoxelBackend")
	if backend:
		voxel_world.move_child(backend, -1)
		# Set the terrain reference
		if "voxel_terrain" in backend:
			backend.voxel_terrain = terrain
	
	# Save the scene
	var packed_scene = PackedScene.new()
	var result = packed_scene.pack(main_instance)
	if result == OK:
		var save_result = ResourceSaver.save(packed_scene, "res://client/scenes/Main.tscn")
		if save_result == OK:
			print("SUCCESS: VoxelTerrain added to Main.tscn!")
			print("")
			print("You can now run the scene:")
			print("  1. Press F1 to start server")
			print("  2. Press 1 to create land")
			print("  3. Press 2 to dig")
		else:
			push_error("Failed to save scene: %s" % save_result)
	else:
		push_error("Failed to pack scene: %s" % result)
	
	main_instance.queue_free()
