extends "res://tests/suite.gd"

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")


## Mock body with a controllable floor height. move_and_slide lands (and zeroes
## downward velocity) when the body descends to floor_y; otherwise it stays
## airborne — enough to exercise simulate_tick's air→ground landing detection.
class FallBody:
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var yaw := 0.0
	var floor_y := -1000.0  # unreachable by default → never lands
	var _on_floor := false
	var _delta := 1.0 / 60.0

	func move_and_slide() -> bool:
		global_position += velocity * _delta
		if global_position.y <= floor_y:
			global_position.y = floor_y
			if velocity.y < 0.0:
				velocity.y = 0.0
			_on_floor = true
		else:
			_on_floor = false
		return velocity.length() > 0.001

	func move_and_collide(motion: Vector3, test_only := false, _margin := 0.001):
		if not test_only:
			global_position += motion
		return null

	func is_on_floor() -> bool:
		return _on_floor

	func apply_floor_snap() -> void:
		pass

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


func _run_tests() -> void:
	_run_method("test_landing_reports_impact_speed")
	_run_method("test_falling_without_landing_reports_zero")
	_run_method("test_staying_grounded_reports_zero")
	_run_method("test_override_landing_reports_zero")


func test_landing_reports_impact_speed() -> void:
	# Falling at ~20 m/s onto a floor just below the feet: the tick lands and the
	# impact speed is exposed (roughly the incoming downward speed).
	var body := FallBody.new()
	body.global_position = Vector3(0, 0.1, 0)
	body.velocity = Vector3(0, -20.0, 0)
	body.floor_y = 0.0
	var state := Movement.MovementState.new()
	state.on_floor = false
	state.velocity = body.velocity
	_sim.simulate_tick(body, state, _make_cmd())
	assert_true(state.on_floor, "should have landed")
	assert_gt(state.landing_impact_speed, 19.0, "impact speed ~ the incoming fall speed")


func test_falling_without_landing_reports_zero() -> void:
	var body := FallBody.new()
	body.global_position = Vector3(0, 50.0, 0)
	body.velocity = Vector3(0, -20.0, 0)  # floor unreachable → keeps falling
	var state := Movement.MovementState.new()
	state.on_floor = false
	state.velocity = body.velocity
	_sim.simulate_tick(body, state, _make_cmd())
	assert_false(state.on_floor, "still airborne")
	assert_eq(state.landing_impact_speed, 0.0, "no landing, no impact")


func test_staying_grounded_reports_zero() -> void:
	# Already on the floor and staying there is not a landing event.
	var body := FallBody.new()
	body.global_position = Vector3(0, 0.0, 0)
	body.floor_y = 0.0
	body._on_floor = true
	var state := Movement.MovementState.new()
	state.on_floor = true
	_sim.simulate_tick(body, state, _make_cmd())
	assert_eq(state.landing_impact_speed, 0.0, "no air→ground transition, no impact")


func test_override_landing_reports_zero() -> void:
	# Velocity-override ticks (ladder/water/grapple) are not free falls — landing
	# during one must not register fall damage (water cushions the fall).
	var body := FallBody.new()
	body.global_position = Vector3(0, 0.1, 0)
	body.velocity = Vector3(0, -20.0, 0)
	body.floor_y = 0.0
	var state := Movement.MovementState.new()
	state.on_floor = false
	state.velocity = body.velocity
	state.velocity_override_active = true
	state.override_velocity = Vector3(0, -20.0, 0)
	_sim.simulate_tick(body, state, _make_cmd())
	assert_eq(state.landing_impact_speed, 0.0, "override landing is cushioned, no impact")
