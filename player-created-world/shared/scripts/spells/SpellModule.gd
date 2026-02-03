class_name SpellModule
extends RefCounted

## Base class for all spell implementations.
## Spells must extend this class and implement the required interface.
##
## Required methods:
##   on_cast(ctx: SpellContext) - Called when the spell is cast
##
## Optional methods:
##   get_manifest() - Return spell metadata
##   on_tick(ctx: SpellContext, dt: float) - Called each frame while active
##   on_cancel(ctx: SpellContext) - Called when spell is cancelled
##   on_event(ctx: SpellContext, event: Dictionary) - Handle custom events


## Return spell metadata/manifest information.
## Override to provide custom metadata.
func get_manifest() -> Dictionary:
	return {
		"name": "Unknown Spell",
		"description": "A spell module",
		"version": 1
	}


## Called when the spell is cast. MUST be implemented by subclasses.
## This is the main entry point for spell execution.
func on_cast(_ctx: SpellContext) -> void:
	push_warning("SpellModule.on_cast() not implemented!")


## Called each frame while the spell is active.
## Override for spells with ongoing effects.
func on_tick(_ctx: SpellContext, _dt: float) -> void:
	pass  # Default: no tick behavior


## Called when the spell is cancelled before completion.
## Override to clean up any ongoing effects.
func on_cancel(_ctx: SpellContext) -> void:
	pass  # Default: no cancel behavior


## Called when a custom event is received.
## Override to handle events from other spells or systems.
func on_event(_ctx: SpellContext, _event: Dictionary) -> void:
	pass  # Default: ignore events


## Helper: Get a value from context params with a default
func get_param(ctx: SpellContext, key: String, default_value = null):
	return ctx.params.get(key, default_value)


## Helper: Check if this spell has an asset loaded
func has_asset(ctx: SpellContext, relative_path: String) -> bool:
	if ctx.world:
		return ctx.world.get_asset(relative_path) != null
	return false
