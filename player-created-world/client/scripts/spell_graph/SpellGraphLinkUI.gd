extends CGEGraphLinkUI
## Custom link UI for spell creation with pulsating glow on running steps.
##
## When the end node has status "running" (active LLM generation), the arrow
## and line pulse with a blue glow to visually indicate progress.

const SpellGraphNode := preload("res://client/scripts/spell_graph/SpellGraphNode.gd")

var _pulse_time: float = 0.0


func _process(delta: float) -> void:
	if _is_end_node_running():
		_pulse_time += delta
		queue_redraw()
	elif _pulse_time > 0.0:
		# Reset after running stops so the glow cleanly disappears
		_pulse_time = 0.0
		queue_redraw()


func _is_end_node_running() -> bool:
	if end_node == null:
		return false
	var spell_data := end_node.graph_element as SpellGraphNode
	if spell_data == null:
		return false
	return spell_data.status == "running"


func _draw() -> void:
	if points.size() <= 1:
		return

	var running := _is_end_node_running()
	var base_col: Color = color if not selected else hover_color
	var pulse: float = 0.0

	if running:
		pulse = sin(_pulse_time * TAU) * 0.5 + 0.5  # 0 → 1, ~1 Hz cycle

		# Glow layer (wider, semi-transparent, blue)
		var glow_col := Color(0.3, 0.7, 1.0, 0.15 + pulse * 0.4)
		var glow_w: float = width + 8.0 + pulse * 6.0
		var gp: PackedVector2Array = PackedVector2Array()
		var gc: PackedColorArray = PackedColorArray()
		for i in range(points.size() - 1):
			gp.append(points[i])
			gp.append(points[i + 1])
			gc.append(glow_col)
		draw_multiline_colors(gp, gc, glow_w, true)

		# Tint the main colour toward blue
		base_col = base_col.lerp(Color(0.3, 0.7, 1.0), pulse * 0.6)

	# Main line
	var lp: PackedVector2Array = PackedVector2Array()
	var lc: PackedColorArray = PackedColorArray()
	for i in range(points.size() - 1):
		lp.append(points[i])
		lp.append(points[i + 1])
		lc.append(base_col)
	draw_multiline_colors(lp, lc, width, antialiased)

	# Arrow head
	if arrow_texture != null and arrow_type == CGEEnum.GraphType.DIRECTED:
		var tip: Vector2 = points[-1]
		var dir: Vector2 = points[-1] - points[-2]
		var ang := atan2(dir.y, dir.x)
		var tex_off: Vector2 = -arrow_texture.get_size() / 2.0

		if running:
			# Scaled glow behind arrow
			var glow_col := Color(0.3, 0.7, 1.0, 0.3 + pulse * 0.5)
			var sc := 1.5 + pulse * 0.5
			draw_set_transform(tip, ang, Vector2(sc, sc))
			draw_texture(arrow_texture, tex_off, glow_col)

		draw_set_transform(tip, ang)
		draw_texture(arrow_texture, tex_off, base_col)
