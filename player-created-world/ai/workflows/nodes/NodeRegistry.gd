class_name WorkflowNodeRegistry
extends RefCounted
## Maps node type strings to handler instances.
##
## Each handler must implement:
##   func run(ctx: WorkflowContext, node_def: Dictionary) -> Dictionary

var _handlers: Dictionary = {}


func _init() -> void:
	_register_builtins()


func _register_builtins() -> void:
	_handlers["llm.chat"] = LLMChatNode.new()
	_handlers["tool.http"] = HTTPRequestNode.new()
	_handlers["transform.text"] = TransformTextNode.new()
	_handlers["control.noop"] = NoopNode.new()


## Register a custom node handler.
func register(type_key: String, handler: RefCounted) -> void:
	_handlers[type_key] = handler


## Check if a type key is registered.
func has_type(type_key: String) -> bool:
	return _handlers.has(type_key)


## Get the handler for a type key (or null).
func get_handler(type_key: String) -> RefCounted:
	return _handlers.get(type_key)
