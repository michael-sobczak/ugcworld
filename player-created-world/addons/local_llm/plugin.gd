@tool
extends EditorPlugin

const AUTOLOAD_NAME = "LocalLLMService"
const AUTOLOAD_PATH = "res://addons/local_llm/scripts/LocalLLMService.gd"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	print("[LocalLLM] Plugin enabled")


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[LocalLLM] Plugin disabled")
