extends "res://tests/suite.gd"
## HullContacts through PmoveCharacter3D: riding, turning with and being pushed by movers.

# Preloaded, not the class_name: a fresh checkout (CI) has no class cache to resolve it from.
const PmoveCharacterScript = preload("res://addons/pmove/pmove_character_3d.gd")


func _slab(size: Vector3, pos: Vector3, mover := false) -> PhysicsBody3D:
	var body: PhysicsBody3D
	if mover:
		var ab := AnimatableBody3D.new()
		# Moved by hand each frame below; the transform goes to the server as it is written.
		ab.sync_to_physics = false
		body = ab
	else:
		body = StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	body.position = pos
	_root().add_child(_keep(body))
	return body


func _character(at: Vector3) -> PmoveCharacterScript:
	var ch := PmoveCharacterScript.new()
	ch.read_input = false
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cs.shape = cap
	ch.add_child(cs)
	ch.position = at
	_root().add_child(_keep(ch))
	return ch


func _ticks(seconds: float) -> int:
	return maxi(roundi(seconds * Engine.physics_ticks_per_second), 1)


## Calls `step` at the top of each physics frame, before the character's own tick, and returns
## once the character has run the last of them.
func _drive(seconds: float, step: Callable) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for i in _ticks(seconds):
		await tree.physics_frame
		step.call()
	await tree.physics_frame


func _settle() -> void:
	await _drive(0.1, func(): pass)


func test_rides_a_sliding_platform() -> void:
	var deck := _slab(Vector3(8, 0.5, 8), Vector3(0, -0.25, 0), true)
	var ch := _character(Vector3(0, 0.01, 0))
	await _settle()
	assert_true(ch.on_floor, "standing on the deck")
	var step := 3.0 / Engine.physics_ticks_per_second
	await _drive(1.0, func(): deck.position.x += step)
	assert_almost_eq(ch.position.x, deck.position.x, 0.1, "carried along with it")
	assert_true(ch.on_floor, "and still standing on it")


func test_turns_with_a_turntable() -> void:
	var deck := _slab(Vector3(8, 0.5, 8), Vector3(0, -0.25, 0), true)
	var ch := _character(Vector3(2, 0.01, 0))
	await _settle()
	var yaw0 := ch.rotation.y
	var step := 1.0 / Engine.physics_ticks_per_second
	await _drive(1.0, func(): deck.rotation.y += step)
	assert_almost_eq(ch.rotation.y - yaw0, deck.rotation.y, 0.05, "faces round with the deck")
	assert_almost_eq(Vector2(ch.position.x, ch.position.z).length(), 2.0, 0.1,
		"and keeps its radius rather than sliding off")
	assert_lt(ch.position.z, -1.0, "having been swept a radian round")


func test_pushed_ahead_of_a_wall() -> void:
	_slab(Vector3(20, 1, 20), Vector3(0, -0.5, 0))
	var wall := _slab(Vector3(4, 3, 0.5), Vector3(0, 1.5, 1.0), true)
	var ch := _character(Vector3(0, 0.01, 0))
	await _settle()
	var step := 2.0 / Engine.physics_ticks_per_second
	await _drive(1.0, func(): wall.position.z -= step)
	assert_lt(ch.position.z, -0.9, "shoved along in front of it")
	assert_lt(ch.position.z, wall.position.z - 0.25 - 0.35, "and kept out of it")


## What a door or a plat reads to decide it is Blocked: resting on a mover stays inside the
## margin, and being crushed into a ceiling by one grows.
func test_reports_a_crush_but_not_a_rest() -> void:
	var deck := _slab(Vector3(4, 0.2, 4), Vector3(0, -0.1, 0), true)
	var elsewhere := _slab(Vector3(1, 1, 1), Vector3(6, 0.5, 0), true)
	var ch := _character(Vector3(0, 0.01, 0))
	_slab(Vector3(4, 0.4, 4), Vector3(0, ch.config.stand_height + 0.5, 0))
	await _settle()
	var resting := ch.contacts.mover_obstruction(deck)
	assert_lt(resting, ch.safe_margin * 2.0, "standing on a still deck is no obstruction")
	assert_eq(ch.contacts.mover_obstruction(elsewhere), 0.0, "an untouched mover has none")
	assert_eq(ch.contacts.mover_obstruction(null), -1.0, "and nothing at all is unmeasured")

	var deepest := [0.0]
	var step := 3.0 / Engine.physics_ticks_per_second
	await _drive(0.7, func():
		deck.position.y += step
		deepest[0] = maxf(deepest[0], ch.contacts.mover_obstruction(deck)))
	assert_gt(deepest[0], ch.safe_margin * 2.0, "rising into the ceiling, the crush shows")


func test_a_teleported_platform_carries_nothing() -> void:
	var deck := _slab(Vector3(8, 0.5, 8), Vector3(0, -0.25, 0), true)
	var ch := _character(Vector3(0, 0.01, 0))
	await _settle()
	var once := [true]
	await _drive(1.0 / 30.0, func():
		if once[0]:
			deck.position.x += 20.0
			once[0] = false)
	assert_almost_eq(ch.position.x, 0.0, 0.01, "a 20 m jump is a reset, not motion")
