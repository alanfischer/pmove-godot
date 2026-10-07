## Lightweight test harness for the pmove suites.
##
## API mirrors Gut (assert_eq, assert_true, ...) so migrating to Gut later is trivial, and
## assertions accumulate rather than abort, so one run reports everything wrong instead of only
## the first failure.
##
## Deliberately no `class_name`: global class names resolve from a cache the editor writes during
## an import pass, which a bare `--headless --path` run does not perform. Suites
## `extends "res://tests/suite.gd"` by path so this runs from a clean checkout with no editor step,
## and for the same reason they preload the classes under test by path rather than by identifier.
##
## Run them all: ./run_tests.sh
extends SceneTree

var _pass_count := 0
var _fail_count := 0
var _current_test := ""

## Scratch nodes registered with _keep(), freed after each test by _teardown_test().
var _spawned: Array[Node] = []


func assert_eq(got, expected, context := "") -> void:
	if got == expected:
		_pass_count += 1
	else:
		_fail("assert_eq: got %s, expected %s%s" % [got, expected, _ctx(context)])


func assert_ne(got, not_expected, context := "") -> void:
	if got != not_expected:
		_pass_count += 1
	else:
		_fail("assert_ne: got %s, should not equal %s%s" % [got, not_expected, _ctx(context)])


func assert_true(value: bool, context := "") -> void:
	if value:
		_pass_count += 1
	else:
		_fail("assert_true: got false%s" % _ctx(context))


func assert_false(value: bool, context := "") -> void:
	if not value:
		_pass_count += 1
	else:
		_fail("assert_false: got true%s" % _ctx(context))


func assert_lt(a, b, context := "") -> void:
	if a < b:
		_pass_count += 1
	else:
		_fail("assert_lt: %s is not < %s%s" % [a, b, _ctx(context)])


func assert_gt(a, b, context := "") -> void:
	if a > b:
		_pass_count += 1
	else:
		_fail("assert_gt: %s is not > %s%s" % [a, b, _ctx(context)])


func assert_almost_eq(got: float, expected: float, tolerance: float, context := "") -> void:
	if absf(got - expected) <= tolerance:
		_pass_count += 1
	else:
		_fail("assert_almost_eq: got %f, expected %f (±%f)%s" % [got, expected, tolerance, _ctx(context)])


func assert_vec3_almost_eq(got: Vector3, expected: Vector3, tolerance: float, context := "") -> void:
	if got.distance_to(expected) <= tolerance:
		_pass_count += 1
	else:
		_fail("assert_vec3_almost_eq: got %s, expected %s (±%f)%s" % [got, expected, tolerance, _ctx(context)])


func _ctx(context: String) -> String:
	return " — %s" % context if not context.is_empty() else ""


func _fail(msg: String) -> void:
	_fail_count += 1
	printerr("  FAIL [%s] %s" % [_current_test, msg])


## Register a node for teardown after the current test. Returns it, so it can wrap the
## construction expression: `var body := _keep(StaticBody3D.new())`.
func _keep(node: Node) -> Node:
	_spawned.append(node)
	return node


## Freed immediately, not queued: a test that traces the physics space must not find the
## previous test's bodies still standing in it, and teardown never yields a frame.
func _despawn_all() -> void:
	for n in _spawned:
		if is_instance_valid(n) and not n.is_queued_for_deletion():
			n.free()
	_spawned.clear()


## Per-test hooks. Override to clear state a suite carries between tests, or to add cleanup
## beyond _spawned (a global system reset, an extra physics frame). Both are awaited, so
## either may be a coroutine.
func _setup_test(_test_name: String) -> void:
	pass


func _teardown_test() -> void:
	_despawn_all()


## Runs every `test_*` method the suite declares, in declaration order, with the hooks above
## around each. Override only for a suite that needs different enumeration — one that repeats
## its tests per map, say (test_bot_waypoints).
func _run_tests() -> void:
	for m in get_method_list():
		var n := String(m.name)
		if not n.begins_with("test_"):
			continue
		_current_test = n
		await _setup_test(n)
		await call(n)
		await _teardown_test()


func _run() -> void:
	var script_path := get_meta("script_path", "") as String
	print("\n=== %s ===" % script_path.get_file() if not script_path.is_empty() else "=== tests ===")
	# Awaited so a suite may make _run_tests a coroutine (see the systems runner);
	# suites that don't resume immediately.
	await _run_tests()
	_print_summary()


func _print_summary() -> void:
	var total := _pass_count + _fail_count
	if _fail_count == 0:
		print("  ✓ %d/%d passed\n" % [_pass_count, total])
	else:
		printerr("  ✗ %d/%d passed (%d failed)\n" % [_pass_count, total, _fail_count])


func _run_method(method_name: String) -> void:
	_current_test = method_name
	call(method_name)


## The live SceneTree's root. Test instances are separate SceneTree objects (not the
## running one), so `self.root` is null — reach the real root via the main loop.
func _root() -> Node:
	return (Engine.get_main_loop() as SceneTree).root
