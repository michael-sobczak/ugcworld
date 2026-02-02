## Connection Dialog - UI for choosing server connection
extends CanvasLayer

signal connection_requested(url: String)
signal dialog_closed

const LOCALHOST_URL := "ws://127.0.0.1:5000"
const PRODUCTION_URL := "wss://ugc-world-backend.fly.dev"

@onready var panel: PanelContainer = $Panel
@onready var localhost_btn: Button = $Panel/VBox/LocalhostBtn
@onready var production_btn: Button = $Panel/VBox/ProductionBtn
@onready var custom_container: HBoxContainer = $Panel/VBox/CustomContainer
@onready var custom_url_input: LineEdit = $Panel/VBox/CustomContainer/CustomURL
@onready var custom_connect_btn: Button = $Panel/VBox/CustomContainer/ConnectBtn
@onready var cancel_btn: Button = $Panel/VBox/CancelBtn
@onready var status_label: Label = $Panel/VBox/StatusLabel


func _ready() -> void:
	# Connect button signals
	localhost_btn.pressed.connect(_on_localhost_pressed)
	production_btn.pressed.connect(_on_production_pressed)
	custom_connect_btn.pressed.connect(_on_custom_connect_pressed)
	cancel_btn.pressed.connect(_on_cancel_pressed)
	custom_url_input.text_submitted.connect(_on_custom_url_submitted)
	
	# Hide by default
	visible = false
	
	# Set placeholder
	custom_url_input.placeholder_text = "ws://host:port or wss://host"


func show_dialog() -> void:
	visible = true
	status_label.text = "Choose a server to connect to"
	status_label.modulate = Color.WHITE
	
	# Focus localhost button by default
	localhost_btn.grab_focus()


func hide_dialog() -> void:
	visible = false
	dialog_closed.emit()


func _on_localhost_pressed() -> void:
	_connect_to(LOCALHOST_URL)


func _on_production_pressed() -> void:
	_connect_to(PRODUCTION_URL)


func _on_custom_connect_pressed() -> void:
	var url = custom_url_input.text.strip_edges()
	if url.is_empty():
		status_label.text = "Please enter a URL"
		status_label.modulate = Color.ORANGE
		return
	
	# Add ws:// if no protocol specified
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		url = "ws://" + url
	
	_connect_to(url)


func _on_custom_url_submitted(url: String) -> void:
	_on_custom_connect_pressed()


func _on_cancel_pressed() -> void:
	hide_dialog()


func _connect_to(url: String) -> void:
	status_label.text = "Connecting to " + url + "..."
	status_label.modulate = Color.CYAN
	connection_requested.emit(url)


func show_error(message: String) -> void:
	status_label.text = message
	status_label.modulate = Color.RED


func show_success(message: String) -> void:
	status_label.text = message
	status_label.modulate = Color.LIME
	# Auto-hide after success
	await get_tree().create_timer(1.0).timeout
	hide_dialog()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			hide_dialog()
			get_viewport().set_input_as_handled()
