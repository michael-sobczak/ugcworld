extends SceneTree

func _initialize() -> void:
	var scene := load("res://test/fixtures/net/TestServer.tscn")
	if scene == null:
		quit(1)
		return
	var instance := scene.instantiate()
	root.add_child(instance)
