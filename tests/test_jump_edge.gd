extends "res://tests/suite.gd"
## Jump is edge-triggered by the sim, as GoldSrc's PM_Jump is through oldbuttons: the
## caller reports the button held, and only a press made with it released jumps.

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const ClientMovementClass = preload("res://addons/pmove/client_movement.gd")

var _sim: Movement.Simulation


## Flat floor at y=0.
class FloorBody:
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var yaw := 0.0

	func move_and_slide() -> bool:
		global_position += velocity * (1.0 / 60.0)
		if global_position.y <= 0.0:
			global_position.y = 0.0
			if velocity.y < 0.0:
				velocity.y = 0.0
		return false

	func move_and_collide(motion: Vector3, _test_only := false, _margin := 0.001):
		global_position += motion
		if global_position.y < 0.0:
			global_position.y = 0.0
		return null

	func is_on_floor() -> bool: return global_position.y <= 0.001
	func apply_floor_snap() -> void: global_position.y = 0.0
	func set_collision_height(_h: float, _c: float) -> void: pass
	func has_headroom(_rise: float, _from_offset := Vector3.ZERO) -> bool: return true


func _cmd(jump: bool, seq := 0) -> InputCommand:
	var cmd := InputCommand.new()
	cmd.seq = seq
	cmd.delta = 1.0 / 60.0
	cmd.jump = jump
	return cmd


func _grounded_state() -> Movement.MovementState:
	var s := Movement.MovementState.new()
	s.on_floor = true
	return s


## Ticks until the body is back on the floor; returns how many jumps took off on the way.
func _count_jumps(body, state: Movement.MovementState, jump: bool, ticks: int) -> int:
	var jumps := 0
	for i in ticks:
		var was_on_floor := state.on_floor
		_sim.simulate_tick(body, state, _cmd(jump))
		if was_on_floor and state.is_jumping:
			jumps += 1
	return jumps


func _run_tests() -> void:
	_sim = Movement.Simulation.new(MovementConfig.new())
	_run_method("test_press_jumps")
	_run_method("test_holding_does_not_pogo")
	_run_method("test_repress_after_landing_jumps")
	_run_method("test_press_in_air_held_through_landing_does_not_jump")
	_run_method("test_reconcile_replays_from_the_servers_jump_held")


func test_press_jumps() -> void:
	var state := _grounded_state()
	_sim.simulate_tick(FloorBody.new(), state, _cmd(true))
	assert_true(state.is_jumping, "a fresh press on the ground jumps")
	assert_true(state.jump_held, "and the tick records the button held")


func test_holding_does_not_pogo() -> void:
	var body := FloorBody.new()
	var state := _grounded_state()
	assert_eq(_count_jumps(body, state, true, 120), 1,
		"holding jump for two seconds jumps once, not again on each landing")


func test_repress_after_landing_jumps() -> void:
	var body := FloorBody.new()
	var state := _grounded_state()
	_count_jumps(body, state, true, 120)
	_sim.simulate_tick(body, state, _cmd(false))
	assert_false(state.jump_held, "a released tick clears it")
	assert_eq(_count_jumps(body, state, true, 1), 1, "and the next press jumps")


func test_press_in_air_held_through_landing_does_not_jump() -> void:
	var body := FloorBody.new()
	body.global_position = Vector3(0, 1, 0)
	var state := Movement.MovementState.new()
	assert_eq(_count_jumps(body, state, true, 120), 0,
		"a press made in the air is spent there, as PM_Jump's oldbuttons makes it")


func test_reconcile_replays_from_the_servers_jump_held() -> void:
	# The client jumps at seq 1 and holds through seq 2. The server answers seq 1 from the
	# floor (it disagrees about the jump), so seq 2 replays from a grounded pose with jump
	# held: whether it jumps is decided by the server's jump_held, not the client's.
	for server_held: bool in [true, false]:
		var cm := ClientMovementClass.new()
		var body := FloorBody.new()
		cm.state.on_floor = true
		cm.predict(body, _cmd(true, cm.get_next_seq()))
		cm.predict(body, _cmd(true, cm.get_next_seq()))
		assert_true(cm.reconcile(body, ClientMovementClass.ServerState.new(
			1, Vector3.ZERO, Vector3.ZERO, false, true, false, server_held)),
			"the server's grounded seq 1 is a correction")
		if server_held:
			assert_false(cm.state.is_jumping, "server held jump: the replay does not jump")
		else:
			assert_true(cm.state.is_jumping, "server released jump: the replay jumps")
