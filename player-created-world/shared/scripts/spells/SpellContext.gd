class_name SpellContext
extends RefCounted

## Context object passed to spell methods during execution.
## Provides access to cast parameters and world interaction APIs.

## The ID of the player/entity casting the spell
var caster_id: String = ""

## Target position in world space
var target_position: Vector3 = Vector3.ZERO

## Target entity ID (if targeting an entity)
var target_entity_id: String = ""

## World API adapter for safe world interactions
var world: WorldAPIAdapter = null

## Random seed for deterministic behaviors (synced across clients)
var random_seed: int = 0

## Random number generator initialized with the seed
var rng: RandomNumberGenerator = null

## Mana/resource budget for this cast
var mana_budget: float = 100.0

## Time this spell was cast (server timestamp)
var cast_time: float = 0.0

## Current tick index (for on_tick calls)
var tick_index: int = 0

## Custom parameters from the cast request
var params: Dictionary = {}

## Manifest data from the spell package
var manifest: Dictionary = {}


func _init() -> void:
	rng = RandomNumberGenerator.new()


## Initialize the context from cast event data
func init_from_cast_event(event: Dictionary) -> void:
	caster_id = event.get("caster_id", "")
	random_seed = event.get("seed", 0)
	rng.seed = random_seed
	
	var cast_params: Dictionary = event.get("cast_params", {})
	params = cast_params
	
	# Parse target position
	var pos_data = cast_params.get("target_position", {})
	if pos_data is Dictionary:
		target_position = Vector3(
			float(pos_data.get("x", 0)),
			float(pos_data.get("y", 0)),
			float(pos_data.get("z", 0))
		)
	elif pos_data is Vector3:
		target_position = pos_data
	
	target_entity_id = cast_params.get("target_entity_id", "")
	mana_budget = float(cast_params.get("mana_budget", 100.0))


## Get a random float using the synced RNG
func randf() -> float:
	return rng.randf()


## Get a random integer in range using the synced RNG
func randi_range(from: int, to: int) -> int:
	return rng.randi_range(from, to)


## Get a random float in range using the synced RNG
func randf_range(from: float, to: float) -> float:
	return rng.randf_range(from, to)
