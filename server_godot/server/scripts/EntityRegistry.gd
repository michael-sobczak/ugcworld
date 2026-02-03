extends Node
## Server-side entity registry.
## Manages all game entities with unique IDs and provides iteration/lookup.

signal entity_spawned(entity_id: int, entity: Node)
signal entity_despawned(entity_id: int)

## Next entity ID to assign
var _next_entity_id: int = 1

## All registered entities: entity_id -> Node
var _entities: Dictionary = {}

## Entities by type: EntityType -> Array[entity_id]
var _entities_by_type: Dictionary = {}

## Reverse lookup: Node -> entity_id
var _node_to_id: Dictionary = {}


func _ready() -> void:
	# Initialize type buckets
	for type in Protocol.EntityType.values():
		_entities_by_type[type] = []


func register_entity(entity_node: Node, entity_type: int, preferred_id: int = 0) -> int:
	"""
	Register an entity and assign it a unique ID.
	Returns the assigned entity_id.
	"""
	var entity_id: int
	if preferred_id > 0 and not _entities.has(preferred_id):
		entity_id = preferred_id
		_next_entity_id = max(_next_entity_id, preferred_id + 1)
	else:
		entity_id = _next_entity_id
		_next_entity_id += 1
	
	_entities[entity_id] = entity_node
	_node_to_id[entity_node] = entity_id
	
	# Add to type bucket
	if not _entities_by_type.has(entity_type):
		_entities_by_type[entity_type] = []
	_entities_by_type[entity_type].append(entity_id)
	
	# Store type on the node if it has the property
	if entity_node.has_method("set_entity_id"):
		entity_node.set_entity_id(entity_id)
	elif "entity_id" in entity_node:
		entity_node.entity_id = entity_id
	
	if "entity_type" in entity_node:
		entity_node.entity_type = entity_type
	
	entity_spawned.emit(entity_id, entity_node)
	return entity_id


func unregister_entity(entity_id: int) -> void:
	"""Unregister an entity by ID."""
	if not _entities.has(entity_id):
		return
	
	var entity_node: Node = _entities[entity_id]
	
	# Remove from type bucket
	for type in _entities_by_type.keys():
		var bucket: Array = _entities_by_type[type]
		var idx := bucket.find(entity_id)
		if idx >= 0:
			bucket.remove_at(idx)
			break
	
	_node_to_id.erase(entity_node)
	_entities.erase(entity_id)
	
	entity_despawned.emit(entity_id)


func unregister_node(entity_node: Node) -> void:
	"""Unregister an entity by node reference."""
	if _node_to_id.has(entity_node):
		unregister_entity(_node_to_id[entity_node])


func get_entity(entity_id: int) -> Node:
	"""Get entity node by ID."""
	return _entities.get(entity_id)


func get_entity_id(entity_node: Node) -> int:
	"""Get entity ID by node."""
	return _node_to_id.get(entity_node, 0)


func has_entity(entity_id: int) -> bool:
	"""Check if entity exists."""
	return _entities.has(entity_id)


func get_all_entities() -> Dictionary:
	"""Get all entities (returns copy)."""
	return _entities.duplicate()


func get_entities_by_type(entity_type: int) -> Array:
	"""Get all entity IDs of a given type."""
	return _entities_by_type.get(entity_type, []).duplicate()


func get_entity_count() -> int:
	"""Get total entity count."""
	return _entities.size()


func get_entities_in_radius(center: Vector3, radius: float, type_filter: int = -1) -> Array:
	"""Get all entities within radius of a point. Returns Array of entity_ids."""
	var result: Array = []
	var radius_sq := radius * radius
	
	var search_entities: Array
	if type_filter >= 0 and _entities_by_type.has(type_filter):
		search_entities = _entities_by_type[type_filter]
	else:
		search_entities = _entities.keys()
	
	for entity_id in search_entities:
		var entity: Node = _entities.get(entity_id)
		if entity == null:
			continue
		
		if entity is Node3D:
			var dist_sq: float = entity.global_position.distance_squared_to(center)
			if dist_sq <= radius_sq:
				result.append(entity_id)
	
	return result


func clear() -> void:
	"""Clear all entities."""
	for entity_id in _entities.keys():
		entity_despawned.emit(entity_id)
	
	_entities.clear()
	_node_to_id.clear()
	for type in _entities_by_type.keys():
		_entities_by_type[type].clear()
	
	_next_entity_id = 1
