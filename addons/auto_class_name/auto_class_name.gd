@tool
extends EditorPlugin

var script_editor: ScriptEditor
var file_system: EditorFileSystem
var tracked_files: Dictionary = {}  # Track file creation times and sizes

func _enter_tree() -> void:
	# Get references to the script editor and file system
	script_editor = get_editor_interface().get_script_editor()
	file_system = get_editor_interface().get_resource_filesystem()
	
	# Initialize tracking of existing files
	_initialize_file_tracking()
	
	# Connect to the file_system's filesystem_changed signal
	file_system.connect("filesystem_changed", _on_filesystem_changed)

func _exit_tree() -> void:
	# Disconnect from signals when plugin is disabled
	if file_system and file_system.is_connected("filesystem_changed", _on_filesystem_changed):
		file_system.disconnect("filesystem_changed", _on_filesystem_changed)

func _initialize_file_tracking() -> void:
	# Scan all existing .gd files and track them
	var dir = DirAccess.open("res://")
	if dir:
		_track_existing_files("res://", dir)

func _track_existing_files(path: String, dir: DirAccess) -> void:
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = path + file_name
			
			if dir.current_is_dir():
				var subdir = DirAccess.open(full_path)
				if subdir:
					_track_existing_files(full_path + "/", subdir)
			elif file_name.ends_with(".gd"):
				# Track this existing file
				var file_info = {
					"modified_time": FileAccess.get_modified_time(full_path),
					"size": _get_file_size(full_path)
				}
				tracked_files[full_path] = file_info
		
		file_name = dir.get_next()
	
	dir.list_dir_end()

func _get_file_size(file_path: String) -> int:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return 0
	var size = file.get_length()
	file.close()
	return size

func _on_filesystem_changed() -> void:
	# Wait a frame to let the file system update
	await get_tree().process_frame
	
	# Check all .gd files in the project
	var dir = DirAccess.open("res://")
	if dir:
		_scan_directory("res://", dir)

func _scan_directory(path: String, dir: DirAccess) -> void:
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = path + file_name
			
			if dir.current_is_dir():
				var subdir = DirAccess.open(full_path)
				if subdir:
					_scan_directory(full_path + "/", subdir)
			elif file_name.ends_with(".gd"):
				_check_if_new_script(full_path)
		
		file_name = dir.get_next()
	
	dir.list_dir_end()

func _check_if_new_script(file_path: String) -> void:
	# Skip if the file is in the addons folder
	if file_path.begins_with("res://addons/"):
		return
	
	var current_modified_time = FileAccess.get_modified_time(file_path)
	var current_size = _get_file_size(file_path)
	
	# Check if this is a truly new file
	var is_new_file = false
	
	if file_path in tracked_files:
		var tracked_info = tracked_files[file_path]
		# File is considered new if it has a different size and very recent modification time
		var time_diff = Time.get_unix_time_from_system() - current_modified_time
		if time_diff < 3.0 and current_size != tracked_info["size"]:
			# Additional check: see if the file content suggests it's a new script
			is_new_file = _is_likely_new_script(file_path)
	else:
		# File wasn't tracked before, so it's new
		var time_diff = Time.get_unix_time_from_system() - current_modified_time
		if time_diff < 3.0:  # Created within last 3 seconds
			is_new_file = true
	
	# Update tracking info
	tracked_files[file_path] = {
		"modified_time": current_modified_time,
		"size": current_size
	}
	
	if is_new_file:
		_add_class_name_to_new_script(file_path)

func _is_likely_new_script(file_path: String) -> bool:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return false
	
	var content = file.get_as_text()
	file.close()
	
	# Check if it's a very minimal script (likely just created)
	var lines = content.split("\n")
	var non_empty_lines = 0
	var has_extends = false
	var has_class_name = false
	
	for line in lines:
		var trimmed = line.strip_edges()
		if trimmed.length() > 0 and not trimmed.begins_with("#"):
			non_empty_lines += 1
			if trimmed.begins_with("extends"):
				has_extends = true
			elif trimmed.begins_with("class_name"):
				has_class_name = true
	
	# Consider it a new script if:
	# - It has very few lines (1-3 non-empty lines)
	# - It has extends but no class_name
	# - Or it's completely empty
	return (non_empty_lines <= 3 and not has_class_name) or non_empty_lines == 0

func _add_class_name_to_new_script(file_path: String) -> void:
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return
	
	var content = file.get_as_text()
	file.close()
	
	# Skip if the file already has a class_name declaration
	if content.find("class_name ") != -1:
		return
	
	# Get the class name from the file name
	var file_name = file_path.get_file()
	var class_name_str = file_name.get_basename()
	
	# Convert to PascalCase (assuming file names are snake_case)
	var parts = class_name_str.split("_")
	class_name_str = ""
	for part in parts:
		if part.length() > 0:
			class_name_str += part[0].to_upper() + part.substr(1)
	
	# Add the class_name at the top of the file
	var new_content = "class_name " + class_name_str + "\n" + content
	
	var write_file = FileAccess.open(file_path, FileAccess.WRITE)
	if write_file:
		write_file.store_string(new_content)
		write_file.close()
		
		# Reload the script if it's currently open
		_reload_current_script(file_path)
		
		print("Added class_name to new script: ", file_path)

func _reload_current_script(file_path: String) -> void:
	# Get all script editor tabs
	var editor_tabs = script_editor.get_open_scripts()
	
	for script_obj in editor_tabs:
		if script_obj.resource_path == file_path:
			# Force reload of the script
			script_editor.reload_scripts()
			break

# Plugin configuration
func get_plugin_name() -> String:
	return "Auto Class Name"

func get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("Script", "EditorIcons")
