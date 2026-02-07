extends GdUnitTestSuite

const GLB_LOADER := preload("res://shared/scripts/util/GlbLoader.gd")

func test_loads_glb_scene() -> void:
	var scene := GLB_LOADER.load_glb("res://sample_assets/Meshy_AI_A_large_iron_witches__0207160856_texture.glb")
	assert_true(scene != null, "GLB should load into a scene node.")
