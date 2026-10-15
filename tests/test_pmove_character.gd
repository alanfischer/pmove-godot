extends "res://tests/suite.gd"
## PmoveCharacter3D: the node runs the kernel, the ladder/water driver and its own signals.

# Preloaded, not the class_name: a fresh checkout (CI) has no class cache to resolve it from.
const PmoveCharacterScript = preload("res://addons/pmove/pmove_character_3d.gd")

const LADDER_LAYER := 4


func _floor() -> void:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	cs.shape = box
	sb.add_child(cs)
	sb.position.y = -0.5
	_root().add_child(_keep(sb))


func _character(shape: Shape3D = null, at := Vector3(0, 0.01, 0)) -> PmoveCharacterScript:
	var ch := PmoveCharacterScript.new()
	ch.read_input = false
	var cs := CollisionShape3D.new()
	if shape == null:
		shape = CapsuleShape3D.new()
		shape.radius = 0.4
	cs.shape = shape
	ch.add_child(cs)
	ch.position = at
	_root().add_child(_keep(ch))
	return ch


## Real physics frames, not hand calls to _physics_process: outside one, move_and_slide
## integrates over the idle frame's delta, which a headless runner spins through in microseconds.
func _run_seconds(seconds: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for i in maxi(roundi(seconds * Engine.physics_ticks_per_second), 1):
		await tree.physics_frame


func test_walks_forward_on_its_own_floor() -> void:
	_floor()
	var ch := _character()
	await _run_seconds(0.1)
	assert_true(ch.on_floor, "settles onto the floor")
	ch.move_input = Vector2(0, -1)
	await _run_seconds(1.0)
	assert_lt(ch.position.z, -4.0, "a second of forward walks it down -z")
	assert_almost_eq(Vector2(ch.velocity.x, ch.velocity.z).length(), ch.config.max_speed, 0.1,
		"at the config's ground speed")


func test_turning_the_node_turns_the_walk() -> void:
	_floor()
	var ch := _character()
	ch.rotation.y = PI / 2.0
	ch.move_input = Vector2(0, -1)
	await _run_seconds(0.5)
	assert_lt(ch.position.x, -1.0, "facing +90 degrees, forward is -x")
	assert_almost_eq(ch.position.z, 0.0, 0.01, "and not -z")


func test_jump_and_land_signal() -> void:
	_floor()
	var ch := _character()
	await _run_seconds(0.1)
	var log := {"jumped": 0, "impact": 0.0}
	ch.jumped.connect(func(): log.jumped += 1)
	ch.landed.connect(func(speed: float): log.impact = speed)
	ch.jump = true
	await _run_seconds(0.0)
	ch.jump = false
	assert_eq(log.jumped, 1, "one jump on the press")
	await _run_seconds(1.5)
	assert_eq(log.jumped, 1, "and no more while airborne")
	assert_gt(log.impact, 5.0, "lands at about the speed it left with")
	assert_true(ch.on_floor, "and is back on the floor")


func test_a_velocity_write_is_kept() -> void:
	_floor()
	var ch := _character()
	await _run_seconds(0.1)
	ch.velocity = Vector3(0, 8, 0)
	await _run_seconds(1.0 / 6.0)
	assert_gt(ch.position.y, 0.5, "a launch the game set carries the body up")


func test_crouch_leaves_a_shared_shape_alone() -> void:
	_floor()
	var shared := CapsuleShape3D.new()
	shared.radius = 0.4
	shared.height = 1.8
	var a := _character(shared, Vector3(-2, 0.01, 0))
	var b := _character(shared, Vector3(2, 0.01, 0))
	a.crouch = true
	await _run_seconds(1.0)
	assert_true(a.is_crouched, "the crouching one is crouched")
	var b_shape := (b.get_child(0) as CollisionShape3D).shape as CapsuleShape3D
	assert_almost_eq(b_shape.height, b.config.stand_height, 0.001, "its neighbour still stands")
	assert_almost_eq(shared.height, 1.8, 0.001, "and the scene's own shape is untouched")


func test_climbs_a_ladder_volume() -> void:
	_floor()
	var area := Area3D.new()
	area.collision_layer = LADDER_LAYER
	area.collision_mask = 0
	area.monitoring = false
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 6, 2)
	cs.shape = box
	area.add_child(cs)
	area.position = Vector3(0, 3, 0)
	_root().add_child(_keep(area))

	var ch := _character()
	ch.ladder_layers = LADDER_LAYER
	await _run_seconds(1.0 / 30.0)
	assert_true(ch.on_ladder, "the waist is in the volume")
	ch.move_input = Vector2(0, -1)
	await _run_seconds(0.5)
	assert_gt(ch.position.y, 1.5, "forward into the ladder's +Z face climbs")
