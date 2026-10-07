extends "res://tests/suite.gd"

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")


## Mock body: flat ground at y=0; move_and_collide applies the motion (unblocked)
## and records it so tests can assert the unstick nudge was swept, and in what
## order relative to the carry.
class UnstickBody:
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var yaw := 0.0
	var collide_calls: Array[Vector3] = []
	var _delta := 1.0 / 60.0

	func move_and_slide() -> bool:
		global_position += velocity * _delta
		if global_position.y <= 0.0:
			global_position.y = 0.0
			if velocity.y < 0.0:
				velocity.y = 0.0
		return velocity.length() > 0.001

	func move_and_collide(motion: Vector3, test_only := false, _margin := 0.001):
		collide_calls.append(motion)
		if not test_only:
			global_position += motion
		return null

	func is_on_floor() -> bool:
		return global_position.y <= 0.001

	func apply_floor_snap() -> void:
		if global_position.y <= 0.01:
			global_position.y = 0.0

	func set_collision_height(_h: float, _c: float) -> void:
		pass

	func has_headroom(_rise: float, _from_offset := Vector3.ZERO) -> bool:
		return true


var _sim: Movement.Simulation


func _init() -> void:
	_sim = Movement.Simulation.new(MovementConfig.new())


func _make_cmd() -> InputCommand:
	var cmd := InputCommand.new()
	cmd.delta = 1.0 / 60.0
	return cmd


func _make_state(on_floor := true) -> Movement.MovementState:
	var s := Movement.MovementState.new()
	s.on_floor = on_floor
	return s


func _run_tests() -> void:
	_run_method("test_depen_moves_body")
	_run_method("test_depen_cleared_after_tick")
	_run_method("test_depen_applies_while_move_locked")
	_run_method("test_depen_applied_after_carry")
	_run_method("test_modifiers_depen_reaches_state")


func test_depen_moves_body() -> void:
	var body := UnstickBody.new()
	var state := _make_state()
	state.depenetration = Vector3(0.0, -0.1, 0.0)  # ejected down out of a ceiling
	_sim.simulate_tick(body, state, _make_cmd())
	assert_gt(body.collide_calls.size(), 0, "depenetration should issue a move_and_collide")
	assert_vec3_almost_eq(body.collide_calls[0], Vector3(0.0, -0.1, 0.0), 0.0001,
		"the collide call should be the depenetration nudge")


func test_depen_cleared_after_tick() -> void:
	var body := UnstickBody.new()
	var state := _make_state()
	state.depenetration = Vector3(0.1, 0.0, 0.0)
	_sim.simulate_tick(body, state, _make_cmd())
	assert_vec3_almost_eq(state.depenetration, Vector3.ZERO, 0.0001,
		"depenetration is per-tick and must be cleared")


func test_depen_applies_while_move_locked() -> void:
	var body := UnstickBody.new()
	var state := _make_state()
	state.is_move_locked = true
	state.depenetration = Vector3(0.0, -0.1, 0.0)
	_sim.simulate_tick(body, state, _make_cmd())
	assert_vec3_almost_eq(body.global_position, Vector3(0.0, -0.1, 0.0), 0.0001,
		"a stunned/embedded rider must still be freed")
	assert_vec3_almost_eq(state.position, body.global_position, 0.0001,
		"state.position must track the depenetrated body")


func test_depen_applied_after_carry() -> void:
	# Both present: carry (ride) is swept first, then the unstick nudge.
	var body := UnstickBody.new()
	var state := _make_state()
	state.carry_motion = Vector3(0.05, 0.0, 0.0)
	state.depenetration = Vector3(0.0, -0.1, 0.0)
	_sim.simulate_tick(body, state, _make_cmd())
	assert_gt(body.collide_calls.size(), 1, "both carry and depenetration should sweep")
	assert_vec3_almost_eq(body.collide_calls[0], Vector3(0.05, 0.0, 0.0), 0.0001,
		"carry ride is applied first")
	assert_vec3_almost_eq(body.collide_calls[1], Vector3(0.0, -0.1, 0.0), 0.0001,
		"depenetration is applied right after the carry")


func test_modifiers_depen_reaches_state() -> void:
	var mods := Movement.MovementModifiers.new()
	mods.depenetration = Vector3(1, 2, 3)
	var state := _make_state()
	mods.apply_to(state)
	assert_vec3_almost_eq(state.depenetration, Vector3(1, 2, 3), 0.0001,
		"apply_to must copy depenetration — replay depends on it")
