extends Node3D
## Visual grid viewer for particle effect eval results.
##
## Loads every generated GDScript file from artifacts/eval/particle_effects/,
## compiles each one, and lays them out in a model x prompt grid with labels.
## Effects replay on a timer so you can compare quality across models.
##
## This script is instantiated by particle_eval_visualizer.gd (the SceneTree
## entry point launched via --script).  Do not run this file directly.
##
## Controls:
##   ESC   — quit
##   SPACE — replay all effects immediately

const EFFECTS_DIR := "res://artifacts/eval/particle_effects/"

const GRID_SPACING_X := 6.0    # distance between columns (models)
const GRID_SPACING_Z := 5.0    # distance between rows (prompts)
const REPLAY_INTERVAL := 4.0   # seconds between automatic replays
const ORBIT_SPEED := 0.12      # radians/s camera orbit
const LABEL_Y := 2.5           # default label height above the grid plane

var _camera: Camera3D
var _camera_pivot: Node3D
var _grid_center := Vector3.ZERO
var _effect_entries: Array = []  # Array of {node: Node3D, pos: Vector3}


# ==============================================================================
# Lifecycle
# ==============================================================================

func _ready() -> void:
	_setup_environment()
	var grid_size := _load_and_display_effects()
	_setup_camera(grid_size)
	if not _effect_entries.is_empty():
		_setup_replay_timer()
		# Wait one frame so every child _ready() has settled, then play.
		await get_tree().process_frame
		_replay_all()


func _process(delta: float) -> void:
	if _camera_pivot:
		_camera_pivot.rotate_y(ORBIT_SPEED * delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				get_tree().quit()
			KEY_SPACE:
				_replay_all()


# ==============================================================================
# Environment (background, lights)
# ==============================================================================

func _setup_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.06, 0.1)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.3, 0.4)
	env.ambient_light_energy = 0.5
	we.environment = env
	add_child(we)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -30, 0)
	light.light_energy = 0.8
	add_child(light)


# ==============================================================================
# Effect loading & grid layout
# ==============================================================================

## Scan the effects directory, parse filenames into a model x prompt grid,
## spawn each effect, and return the grid dimensions.
func _load_and_display_effects() -> Vector2i:
	var dir := DirAccess.open(EFFECTS_DIR)
	if dir == null:
		push_warning("No effects directory: %s -- run eval tests first." % EFFECTS_DIR)
		_add_label(
			"No particle effects found.\nRun: scripts/run_tests.ps1 -Mode eval",
			Vector3(0, 2, 0), 64, Color(1, 0.8, 0.3))
		return Vector2i.ZERO

	# Gather .gd filenames
	var files: PackedStringArray = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".gd"):
			files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	if files.is_empty():
		_add_label(
			"No particle effects found.\nRun: scripts/run_tests.ps1 -Mode eval",
			Vector3(0, 2, 0), 64, Color(1, 0.8, 0.3))
		return Vector2i.ZERO

	files.sort()

	# Parse filenames into structured data.
	# Filename format: {model_id}__{prompt_slug}.gd
	var models: PackedStringArray = []
	var prompts: PackedStringArray = []
	var lookup: Dictionary = {}  # "model\tprompt" -> filepath

	for f in files:
		var base := f.get_basename()
		var sep := base.find("__")
		if sep < 0:
			continue
		var model_id := base.substr(0, sep)
		var prompt_label := base.substr(sep + 2).replace("_", " ")

		if model_id not in models:
			models.append(model_id)
		if prompt_label not in prompts:
			prompts.append(prompt_label)
		lookup[model_id + "\t" + prompt_label] = EFFECTS_DIR + f

	var n_models := models.size()
	var n_prompts := prompts.size()
	print("[viewer] Found %d effect scripts (%d models x %d prompts)" % [
		files.size(), n_models, n_prompts])

	# ---- Title ----
	var title_x := float(n_models - 1) * GRID_SPACING_X * 0.5
	_add_label("Particle Effect Eval Results",
		Vector3(title_x, LABEL_Y + 2.5, -3.5), 72, Color(1.0, 1.0, 1.0))
	_add_label("ESC = quit | SPACE = replay",
		Vector3(title_x, LABEL_Y + 1.5, -3.5), 36, Color(0.6, 0.6, 0.7))

	# ---- Column headers (model names) ----
	for col in range(n_models):
		var pos := Vector3(col * GRID_SPACING_X, LABEL_Y + 0.5, -1.5)
		_add_label(models[col], pos, 52, Color(1.0, 0.85, 0.4))

	# ---- Rows (prompts) with effects ----
	for row in range(n_prompts):
		# Row label on the left
		_add_label(prompts[row],
			Vector3(-3.5, LABEL_Y * 0.5, row * GRID_SPACING_Z),
			44, Color(0.75, 0.75, 0.85))

		for col in range(n_models):
			var key := models[col] + "\t" + prompts[row]
			var cell_pos := Vector3(col * GRID_SPACING_X, 0.0, row * GRID_SPACING_Z)

			if key in lookup:
				_spawn_effect(lookup[key], cell_pos)
			else:
				# Missing combination — show placeholder
				_add_label("--",
					cell_pos + Vector3(0, 1, 0), 64, Color(0.4, 0.4, 0.4))

	return Vector2i(n_models, n_prompts)


## Load, compile, instantiate, and position a single particle effect.
func _spawn_effect(filepath: String, pos: Vector3) -> void:
	var f := FileAccess.open(filepath, FileAccess.READ)
	if f == null:
		push_warning("Cannot read %s" % filepath)
		return
	var source := f.get_as_text()
	f.close()

	var script := GDScript.new()
	script.source_code = source
	var err := script.reload()
	if err != OK:
		push_warning("Compile error in %s (code %d)" % [filepath, err])
		_add_label("COMPILE\nERROR", pos + Vector3(0, 1.0, 0), 48, Color(1, 0.2, 0.2))
		return

	var inst = script.new()
	if not (inst is Node3D):
		push_warning("Not a Node3D: %s" % filepath)
		if inst is Node:
			(inst as Node).queue_free()
		return

	var node: Node3D = inst as Node3D
	node.position = pos
	add_child(node)

	# After add_child, the node's _ready() has fired and created its children
	# (GPUParticles3D, Timer, etc.).  Disconnect the auto-destruct timer so
	# the effect stays alive for repeated replays.
	_defuse_timers(node)

	_effect_entries.append({node = node, pos = pos})


## Recursively find Timer nodes and disconnect their timeout signals
## to prevent queue_free() from destroying the effect after one play.
func _defuse_timers(node: Node) -> void:
	for child in node.get_children():
		if child is Timer:
			var conns: Array = child.get_signal_connection_list("timeout")
			for conn in conns:
				child.disconnect("timeout", conn["callable"])
			child.stop()
		_defuse_timers(child)


# ==============================================================================
# Replay
# ==============================================================================

func _setup_replay_timer() -> void:
	var t := Timer.new()
	t.wait_time = REPLAY_INTERVAL
	t.one_shot = false
	t.autostart = true
	t.timeout.connect(_replay_all)
	add_child(t)


func _replay_all() -> void:
	for entry in _effect_entries:
		var node: Node3D = entry.node
		var pos: Vector3 = entry.pos
		if is_instance_valid(node) and node.has_method("play_at"):
			node.play_at(pos)


# ==============================================================================
# Camera
# ==============================================================================

func _setup_camera(grid_size: Vector2i) -> void:
	var total_w := maxf(float(grid_size.x - 1) * GRID_SPACING_X, 0.0)
	var total_d := maxf(float(grid_size.y - 1) * GRID_SPACING_Z, 0.0)
	_grid_center = Vector3(total_w * 0.5, 0.0, total_d * 0.5)

	# Pivot at grid center — camera orbits around it
	_camera_pivot = Node3D.new()
	_camera_pivot.position = _grid_center
	add_child(_camera_pivot)

	_camera = Camera3D.new()
	var dist := maxf(total_w, total_d) * 0.7 + 10.0
	_camera.position = Vector3(0.0, dist * 0.25, dist * 0.55)
	_camera_pivot.add_child(_camera)
	# look_at() requires the node to be in the tree and uses global coords.
	# Target slightly above grid center so the grid is vertically centered.
	_camera.look_at(_grid_center + Vector3(0.0, 1.0, 0.0))


# ==============================================================================
# Labels
# ==============================================================================

func _add_label(text: String, pos: Vector3, font_size: int = 48,
		color: Color = Color.WHITE) -> void:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.position = pos
	lbl.font_size = font_size
	lbl.pixel_size = 0.01
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.modulate = color
	lbl.outline_size = 8
	lbl.outline_modulate = Color(0, 0, 0, 0.8)
	add_child(lbl)
