## Test runner for the suites in this directory — discovers and runs every test_*.gd beside it.
##
##   godot --headless --path . -s res://tests/run_tests.gd
##
## A suite is a script extending suite.gd; the runner instantiates each and calls _run(), which
## enumerates its test_* methods. Nothing here boots a scene, so the whole suite runs headless
## from a clean checkout with no editor import pass.
extends SceneTree

const TEST_DIR := "res://tests/"

var _total_pass := 0
var _total_fail := 0


func _init() -> void:
	var dir := DirAccess.open(TEST_DIR)
	if not dir:
		printerr("Could not open test directory: %s" % TEST_DIR)
		quit(1)
		return

	var test_files: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			test_files.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()
	test_files.sort()

	if test_files.is_empty():
		printerr("No test files found in %s" % TEST_DIR)
		quit(1)
		return

	print("\n====== pmove test suite ======\n")

	for tf in test_files:
		var script_path := TEST_DIR + tf
		var script: GDScript = load(script_path)
		# A suite that fails to parse comes back as a GDScript that cannot be instantiated, not
		# as null. Calling new() on it raises, and a raise in _init aborts the rest of _init --
		# including the quit() below, which leaves a headless run hanging with no main scene
		# instead of reporting the broken suite. So check before calling.
		if script == null or not script.can_instantiate():
			printerr("Failed to load (see the parse errors above): %s" % script_path)
			_total_fail += 1
			continue

		var instance = script.new()
		instance.set_meta("script_path", script_path)
		instance._run()
		_total_pass += instance._pass_count
		_total_fail += instance._fail_count

	var total := _total_pass + _total_fail
	print("====== TOTAL: %d/%d passed ======" % [_total_pass, total])
	if _total_fail > 0:
		printerr("====== %d FAILED ======" % _total_fail)
	quit(1 if _total_fail > 0 else 0)
