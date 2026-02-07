class_name TestLog
extends RefCounted

var _file: FileAccess = null
var _path: String = ""

func open(path: String) -> void:
	_path = path
	if _path == "":
		return
	var abs_path := ProjectSettings.globalize_path(_path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	_file = FileAccess.open(abs_path, FileAccess.WRITE)

func info(message: String) -> void:
	_write("INFO", message)

func warn(message: String) -> void:
	_write("WARN", message)

func error(message: String) -> void:
	_write("ERROR", message)

func event(name: String, payload: Dictionary) -> void:
	if _path == "":
		return
	var abs_path := ProjectSettings.globalize_path(_path)
	var events_path := abs_path + ".events.jsonl"
	var file := FileAccess.open(events_path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(events_path, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	var entry := {
		"timestamp": _timestamp(),
		"event": name,
		"data": payload
	}
	file.store_string(JSON.stringify(entry) + "\n")
	file.close()

func close() -> void:
	if _file != null:
		_file.close()
		_file = null

func _write(level: String, message: String) -> void:
	var line := "[%s] [%s] %s\n" % [_timestamp(), level, message]
	print(line.strip_edges())
	if _file != null:
		_file.store_string(line)
		_file.flush()

func _timestamp() -> String:
	return Time.get_datetime_string_from_system()
