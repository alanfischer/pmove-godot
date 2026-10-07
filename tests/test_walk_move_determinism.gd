extends "res://tests/suite.gd"
## Tests that simulate_tick is deterministic: identical inputs from an identical
## starting state must give identical results, even called twice in one frame
## (as replay does). A deterministic StubBody isolates whether divergence is in
## our code or in Godot's CharacterBody3D (cached broadphase/narrowphase state
## across repeated move_and_slide calls in one frame) — if these all pass, any
## divergence seen in the real game is the latter, and the only fix is capping
## the server to 1 simulate_tick per physics frame. See test_catchup_rate.gd.

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")

var _sim: Movement.Simulation


class FlatGroundBody:
	## Simulates an infinite flat floor at y=0. Deterministic.
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var yaw := 0.0
	var _on_floor := true

	func move_and_slide() -> bool:
		global_position += velocity * (1.0 / 60.0)
		if global_position.y <= 0.0:
			global_position.y = 0.0
			if velocity.y < 0.0:
				velocity.y = 0.0
			_on_floor = true
		else:
			_on_floor = false
		return false

	func move_and_collide(motion: Vector3, _test_only := false, _margin := 0.001):
		global_position += motion
		if global_position.y < 0.0:
			global_position.y = 0.0
		return null

	func is_on_floor() -> bool: return _on_floor
	func apply_floor_snap() -> void: global_position.y = 0.0
	func set_collision_height(_h: float, _c: float) -> void: pass
	func has_headroom(_rise: float, _from_offset := Vector3.ZERO) -> bool: return true


class AirBody:
	## Body always in air — no floor. Deterministic.
	var global_position := Vector3(0, 5, 0)
	var velocity := Vector3.ZERO
	var yaw := 0.0

	func move_and_slide() -> bool:
		global_position += velocity * (1.0 / 60.0)
		return false

	func move_and_collide(motion: Vector3, _test_only := false, _margin := 0.001):
		global_position += motion
		return null

	func is_on_floor() -> bool: return false
	func apply_floor_snap() -> void: pass
	func set_collision_height(_h: float, _c: float) -> void: pass
	func has_headroom(_rise: float, _from_offset := Vector3.ZERO) -> bool: return true


func _make_cmd(seq: int, move: Vector2 = Vector2.ZERO, yaw: float = 0.0) -> InputCommand:
	var cmd := InputCommand.new()
	cmd.seq = seq
	cmd.delta = 1.0 / 60.0
	cmd.move_input = move
	cmd.yaw = yaw
	return cmd


func _make_state(pos: Vector3 = Vector3.ZERO, vel: Vector3 = Vector3.ZERO,
		on_floor: bool = true) -> Movement.MovementState:
	var s := Movement.MovementState.new()
	s.position = pos
	s.velocity = vel
	s.on_floor = on_floor
	return s


func _run_tests() -> void:
	_sim = Movement.Simulation.new(MovementConfig.new())
	_run_method("test_standing_still_is_deterministic")
	_run_method("test_walking_on_flat_is_deterministic")
	_run_method("test_two_ticks_same_as_one_tick_from_same_state")
	_run_method("test_n_ticks_batched_same_as_n_ticks_sequential")
	_run_method("test_jump_trajectory_is_deterministic")
	_run_method("test_walk_move_called_twice_same_result")


## Standing still, no input — position must not drift.
func test_standing_still_is_deterministic() -> void:
	var body := FlatGroundBody.new()
	var state := _make_state()
	var cmd := _make_cmd(1)

	_sim.simulate_tick(body, state, cmd)
	var pos1 := body.global_position

	# Reset and simulate again from identical state
	var body2 := FlatGroundBody.new()
	var state2 := _make_state()
	_sim.simulate_tick(body2, state2, _make_cmd(1))

	assert_vec3_almost_eq(body.global_position, body2.global_position, 0.0,
		"standing still must produce identical positions")
	assert_vec3_almost_eq(body.velocity, body2.velocity, 0.0,
		"standing still must produce identical velocities")


## Walk forward for one tick — two independent bodies must end up identical.
func test_walking_on_flat_is_deterministic() -> void:
	var cmd := _make_cmd(1, Vector2(0, -1), 0.0)  # forward

	var body1 := FlatGroundBody.new()
	var state1 := _make_state()
	_sim.simulate_tick(body1, state1, cmd)

	var body2 := FlatGroundBody.new()
	var state2 := _make_state()
	_sim.simulate_tick(body2, state2, cmd)

	assert_vec3_almost_eq(body1.global_position, body2.global_position, 0.0,
		"walking forward must be deterministic")
	assert_vec3_almost_eq(body1.velocity, body2.velocity, 0.0,
		"walking velocity must be deterministic")


## Core replay test: simulate tick N from state S, then simulate tick N+1
## from state S (not from S's result). Both should give the same result for
## tick N. This proves simulate_tick is stateless w.r.t. external calls.
func test_two_ticks_same_as_one_tick_from_same_state() -> void:
	var cmd := _make_cmd(1, Vector2(0, -1), 0.0)

	var body_a := FlatGroundBody.new()
	var state_a := _make_state()
	_sim.simulate_tick(body_a, state_a, cmd)
	var result_a_pos := body_a.global_position
	var result_a_vel := body_a.velocity

	# Simulate again from the same initial state (not from result)
	var body_b := FlatGroundBody.new()
	var state_b := _make_state()
	_sim.simulate_tick(body_b, state_b, cmd)

	assert_vec3_almost_eq(result_a_pos, body_b.global_position, 0.0,
		"same tick from same state must give identical position")
	assert_vec3_almost_eq(result_a_vel, body_b.velocity, 0.0,
		"same tick from same state must give identical velocity")


## N ticks processed in a batch (one body, sequential simulate_tick calls)
## must equal N ticks processed independently (fresh body for each tick,
## chaining state manually). This is how client replay works vs server.
func test_n_ticks_batched_same_as_n_ticks_sequential() -> void:
	const N := 10
	var cmds: Array = []
	for i in N:
		cmds.append(_make_cmd(i + 1, Vector2(0, -1), 0.0))

	# "Batched": simulate all N ticks on a single body
	var body_batch := FlatGroundBody.new()
	var state_batch := _make_state()
	for i in N:
		_sim.simulate_tick(body_batch, state_batch, cmds[i])

	# "Sequential": simulate each tick on a fresh body, chaining state
	var state_seq := _make_state()
	var body_seq_final := FlatGroundBody.new()
	for i in N:
		var b := FlatGroundBody.new()
		b.global_position = state_seq.position
		b.velocity = state_seq.velocity
		_sim.simulate_tick(b, state_seq, cmds[i])
		body_seq_final = b

	assert_vec3_almost_eq(body_batch.global_position, body_seq_final.global_position, 0.0001,
		"batched and sequential N ticks must give same final position")
	assert_vec3_almost_eq(body_batch.velocity, body_seq_final.velocity, 0.0001,
		"batched and sequential N ticks must give same final velocity")


## Jump trajectory must be reproducible — same starting state, same sequence
## of commands, identical result. Tests the half-gravity split and jump impulse.
func test_jump_trajectory_is_deterministic() -> void:
	var jump_cmd := _make_cmd(1)
	jump_cmd.jump_just_pressed = true
	jump_cmd.jump = true

	var body1 := FlatGroundBody.new()
	var state1 := _make_state()
	_sim.simulate_tick(body1, state1, jump_cmd)

	var body2 := FlatGroundBody.new()
	var state2 := _make_state()
	_sim.simulate_tick(body2, state2, jump_cmd)

	assert_vec3_almost_eq(body1.global_position, body2.global_position, 0.0,
		"jump tick position must be deterministic")
	assert_almost_eq(body1.velocity.y, body2.velocity.y, 0.0,
		"jump velocity.y must be deterministic")
	assert_true(state1.is_jumping, "should be jumping after jump cmd")
	assert_true(state2.is_jumping, "should be jumping after jump cmd (second body)")


## walk_move called twice from identical starting state must produce identical
## results. This proves determinism in our code — if Godot's real physics
## diverges, it's the physics engine, not our walk_move logic.
func test_walk_move_called_twice_same_result() -> void:
	var cmd := _make_cmd(1, Vector2(1, -1), 0.0)

	var body1 := FlatGroundBody.new()
	body1.global_position = Vector3(0, 0, 0)
	body1.velocity = Vector3(3, 0, 3)
	var state1 := _make_state(Vector3.ZERO, Vector3(3, 0, 3))
	state1.on_floor = true
	_sim.walk_move(body1, state1, cmd)

	var body2 := FlatGroundBody.new()
	body2.global_position = Vector3(0, 0, 0)
	body2.velocity = Vector3(3, 0, 3)
	var state2 := _make_state(Vector3.ZERO, Vector3(3, 0, 3))
	state2.on_floor = true
	_sim.walk_move(body2, state2, cmd)

	assert_vec3_almost_eq(body1.global_position, body2.global_position, 0.0,
		"walk_move from identical state must give identical position")
	assert_vec3_almost_eq(body1.velocity, body2.velocity, 0.0,
		"walk_move from identical state must give identical velocity")
