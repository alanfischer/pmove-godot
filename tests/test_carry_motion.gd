extends "res://tests/suite.gd"

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")


## Mock body: flat ground at y=0; move_and_collide applies the motion
## (unblocked) and records it so tests can assert the carry was swept.
class CarryBody:
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


func _make_cmd(move := Vector2.ZERO) -> InputCommand:
	var cmd := InputCommand.new()
	cmd.delta = 1.0 / 60.0
	cmd.move_input = move
	return cmd


func _make_state(on_floor := true) -> Movement.MovementState:
	var s := Movement.MovementState.new()
	s.on_floor = on_floor
	return s


func _run_tests() -> void:
	_run_method("test_carry_moves_body_before_locomotion")
	_run_method("test_carry_cleared_after_tick")
	_run_method("test_zero_carry_no_collide_call")
	_run_method("test_carry_applies_while_move_locked")
	_run_method("test_modifiers_carry_reaches_state")


func test_carry_moves_body_before_locomotion() -> void:
	var body := CarryBody.new()
	var state := _make_state()
	state.carry_motion = Vector3(0.05, 0.0, -0.02)
	_sim.simulate_tick(body, state, _make_cmd())
	assert_gt(body.collide_calls.size(), 0, "carry should issue a move_and_collide")
	assert_vec3_almost_eq(body.collide_calls[0], Vector3(0.05, 0.0, -0.02), 0.0001,
		"first collide call should be the carry motion")


func test_carry_cleared_after_tick() -> void:
	var body := CarryBody.new()
	var state := _make_state()
	state.carry_motion = Vector3(0.05, 0.0, 0.0)
	_sim.simulate_tick(body, state, _make_cmd())
	assert_vec3_almost_eq(state.carry_motion, Vector3.ZERO, 0.0001,
		"carry_motion is per-tick and must be cleared")


func test_zero_carry_no_collide_call() -> void:
	var body := CarryBody.new()
	var state := _make_state()
	_sim.simulate_tick(body, state, _make_cmd())
	# The step path may call move_and_collide, but only when there is horizontal
	# velocity — a standing tick with zero carry must not sweep anything.
	assert_eq(body.collide_calls.size(), 0, "no carry, no input: no collide sweeps")


func test_carry_applies_while_move_locked() -> void:
	var body := CarryBody.new()
	var state := _make_state()
	state.is_move_locked = true
	state.carry_motion = Vector3(0.0, 0.0, 0.1)
	_sim.simulate_tick(body, state, _make_cmd())
	assert_vec3_almost_eq(body.global_position, Vector3(0.0, 0.0, 0.1), 0.0001,
		"a stunned rider still rides the mover")
	assert_vec3_almost_eq(state.position, body.global_position, 0.0001,
		"state.position must track the carried body")


func test_modifiers_carry_reaches_state() -> void:
	var mods := Movement.MovementModifiers.new()
	mods.carry_motion = Vector3(1, 2, 3)
	var state := _make_state()
	mods.apply_to(state)
	assert_vec3_almost_eq(state.carry_motion, Vector3(1, 2, 3), 0.0001,
		"apply_to must copy carry_motion — replay depends on it")
