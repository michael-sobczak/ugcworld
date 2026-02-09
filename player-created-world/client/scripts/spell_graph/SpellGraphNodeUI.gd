extends CGEGraphNodeUI
## Visual representation of a spell pipeline step in the graph editor.
##
## Shows only the step title inside the node body.  A small coloured dot in
## the top-right corner indicates the current status (pending / running /
## done / error).  Click the node to see full input/output details.

const SpellGraphNode := preload("res://client/scripts/spell_graph/SpellGraphNode.gd")

@onready var title_label: Label = %TitleLabel

## Colours per status
const STATUS_COLORS: Dictionary = {
	"pending": Color(0.5, 0.5, 0.5),
	"running": Color(0.3, 0.7, 1.0),
	"done": Color(0.3, 0.85, 0.3),
	"error": Color(1.0, 0.3, 0.3),
}

## Background colours per step type  (keyed by StepType enum value)
const TYPE_COLORS: Dictionary = {
	0: Color(0.25, 0.25, 0.35, 0.95),  # USER_INPUT
	1: Color(0.2, 0.3, 0.45, 0.95),    # DESCRIPTION
	2: Color(0.3, 0.25, 0.4, 0.95),    # ASSET_MANIFEST
	3: Color(0.4, 0.25, 0.2, 0.95),    # PARTICLE
	4: Color(0.2, 0.35, 0.25, 0.95),   # SHAPE
	5: Color(0.35, 0.35, 0.2, 0.95),   # SANITIZE
	6: Color(0.25, 0.3, 0.35, 0.95),   # HUMAN_REVIEW
	7: Color(0.35, 0.25, 0.35, 0.95),  # VALIDATE
	8: Color(0.2, 0.35, 0.3, 0.95),    # COMPILE_SAVE
}


func _ready() -> void:
	custom_minimum_size = Vector2(130, 45)
	_update_ui_from_data()


func _draw() -> void:
	var node_data: SpellGraphNode = graph_element as SpellGraphNode
	var bg_color: Color = Color(0.25, 0.25, 0.3, 0.95)
	if node_data != null:
		bg_color = TYPE_COLORS.get(node_data.step_type, bg_color) as Color

	# Background fill
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)

	# Border
	var border_color: Color = Color(0.8, 0.8, 0.8) if selected else Color(0.45, 0.45, 0.45)
	var border_w: float = 2.5 if selected else 1.0
	draw_rect(Rect2(Vector2.ZERO, size), border_color, false, border_w)

	# Status dot (top-right corner)
	if node_data != null:
		var dot_color: Color = STATUS_COLORS.get(node_data.status, Color.GRAY) as Color
		var dot_pos := Vector2(size.x - 10.0, 10.0)
		draw_circle(dot_pos, 4.0, dot_color)


func _update_ui_from_data() -> void:
	var node_data: SpellGraphNode = graph_element as SpellGraphNode
	if node_data == null:
		return
	if title_label:
		title_label.text = node_data.step_label if not node_data.step_label.is_empty() else "Step %d" % node_data.id


func refresh() -> void:
	_update_ui_from_data()
	queue_redraw()
