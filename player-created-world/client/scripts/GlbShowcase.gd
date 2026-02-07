extends Node3D

const MODEL_PATH := "res://sample_assets/Meshy_AI_A_large_iron_witches__0207160856_texture.glb"
const GLB_LOADER := preload("res://shared/scripts/util/GlbLoader.gd")
const MODEL_POSITION := Vector3(0.0, 0.5, 0.0)

var _instance: Node = null

func _ready() -> void:
	var net := get_node_or_null("/root/Net")
	if net:
		net.world_joined.connect(_on_world_joined)
	else:
		_showcase()

func _on_world_joined(_world_id: String, _world: Dictionary) -> void:
	_showcase()

func _showcase() -> void:
	if _instance != null:
		return
	var scene := GLB_LOADER.load_glb(MODEL_PATH)
	if scene == null:
		return
	_instance = scene
	add_child(_instance)
	if _instance is Node3D:
		var node3d := _instance as Node3D
		node3d.global_position = MODEL_POSITION
