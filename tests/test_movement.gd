extends "res://tests/suite.gd"

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")

var _sim: Movement.Simulation


func _init() -> void:
	_sim = Movement.Simulation.new(MovementConfig.new())


func _make_state(vel := Vector3.ZERO, on_floor := true) -> Movement.MovementState:
	var s := Movement.MovementState.new()
	s.velocity = vel
	s.on_floor = on_floor
	return s


## Minimal Body for the crouch tests: records the hull it was told to build and
## answers the headroom question however the test wants.
class CrouchBody:
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var yaw := 0.0
	var height := 0.0          # set by set_collision_height, never guessed
	var uncrouch_ok := true
	func move_and_slide() -> void: pass
	func move_and_collide(_m: Vector3): return null
	func is_on_floor() -> bool: return true
	func apply_floor_snap() -> void: pass
	func set_collision_height(h: float, _c: float) -> void: height = h
	func has_headroom(_rise: float, _from_offset := Vector3.ZERO) -> bool: return uncrouch_ok


func _make_cmd(move := Vector2.ZERO, yaw := 0.0, delta := 1.0 / 60.0) -> InputCommand:
	var cmd := InputCommand.new()
	cmd.move_input = move
	cmd.yaw = yaw
	cmd.delta = delta
	return cmd


func _run_tests() -> void:
	_run_method("test_apply_friction_reduces_speed")
	_run_method("test_apply_friction_stops_below_threshold")
	_run_method("test_apply_friction_respects_friction_scale")
	_run_method("test_ground_accelerate_toward_wish")
	_run_method("test_ground_accelerate_capped_at_max")
	_run_method("test_ground_accelerate_respects_accel_scale")
	_run_method("test_air_accelerate_speed_cap")
	_run_method("test_air_accelerate_preserves_existing_speed")
	_run_method("test_gravity_applied_airborne")
	_run_method("test_gravity_respects_gravity_scale")
	_run_method("test_get_max_speed_crouch")
	_run_method("test_get_max_speed_walk")
	_run_method("test_get_max_speed_speed_scale")
	_run_method("test_get_max_speed_stacks")
	_run_method("test_clamp_velocity")
	_run_method("test_is_move_locked_zeroes_velocity")
	_run_method("test_calc_wish_forward")
	_run_method("test_calc_wish_strafe")
	_run_method("test_calc_wish_no_input")
	_run_method("test_duck_on_ground_keeps_feet_planted")
	_run_method("test_duck_in_air_lifts_the_feet")
	_run_method("test_unduck_in_air_drops_the_feet_back")
	_run_method("test_unduck_in_air_blocked_keeps_the_lift")
	_run_method("test_restore_resyncs_the_hull_to_the_restored_crouch")


# --- apply_friction ---

func test_apply_friction_reduces_speed() -> void:
	var state := _make_state(Vector3(5, 0, 0))
	_sim.apply_friction(state, 1.0 / 60.0)
	assert_lt(state.velocity.length(), 5.0, "friction should reduce speed")


func test_apply_friction_stops_below_threshold() -> void:
	var state := _make_state(Vector3(0.05, 0, 0))
	_sim.apply_friction(state, 1.0 / 60.0)
	assert_almost_eq(state.velocity.x, 0.0, 0.001, "near-zero should zero out")
	assert_almost_eq(state.velocity.z, 0.0, 0.001, "near-zero should zero out")


func test_apply_friction_respects_friction_scale() -> void:
	var state_normal := _make_state(Vector3(5, 0, 0))
	var state_double := _make_state(Vector3(5, 0, 0))
	state_double.friction_scale = 2.0
	_sim.apply_friction(state_normal, 1.0 / 60.0)
	_sim.apply_friction(state_double, 1.0 / 60.0)
	assert_lt(state_double.velocity.length(), state_normal.velocity.length(),
		"friction_scale=2 should slow more than 1")


# --- ground_accelerate ---

func test_ground_accelerate_toward_wish() -> void:
	var state := _make_state()
	var wish_dir := Vector3(0, 0, -1)
	_sim.ground_accelerate(state, wish_dir, _sim.cfg.max_speed, 1.0 / 60.0)
	assert_lt(state.velocity.z, 0.0, "should accelerate in -Z direction")


func test_ground_accelerate_capped_at_max() -> void:
	var state := _make_state(Vector3(0, 0, -_sim.cfg.max_speed))
	var wish_dir := Vector3(0, 0, -1)
	var vel_before := state.velocity
	_sim.ground_accelerate(state, wish_dir, _sim.cfg.max_speed, 1.0 / 60.0)
	assert_almost_eq(state.velocity.z, vel_before.z, 0.001,
		"should not exceed max speed")


func test_ground_accelerate_respects_accel_scale() -> void:
	var state_normal := _make_state()
	var state_boosted := _make_state()
	state_boosted.accel_scale = 2.0
	var wish_dir := Vector3(0, 0, -1)
	_sim.ground_accelerate(state_normal, wish_dir, _sim.cfg.max_speed, 1.0 / 60.0)
	_sim.ground_accelerate(state_boosted, wish_dir, _sim.cfg.max_speed, 1.0 / 60.0)
	assert_lt(state_boosted.velocity.z, state_normal.velocity.z,
		"accel_scale=2 should accelerate more (more negative Z)")


# --- air_accelerate ---

func test_air_accelerate_speed_cap() -> void:
	var state := _make_state(Vector3(_sim.cfg.max_speed, 0, 0), false)
	var wish_dir := Vector3(0, 0, -1)
	_sim.air_accelerate(state, wish_dir, _sim.cfg.max_speed, 1.0 / 60.0)
	assert_lt(absf(state.velocity.z), _sim.cfg.air_speed_cap + 0.01,
		"air accel should be capped")


func test_air_accelerate_preserves_existing_speed() -> void:
	var state := _make_state(Vector3(0, 0, -_sim.cfg.max_speed * 2), false)
	var vel_before := state.velocity.z
	var wish_dir := Vector3(0, 0, -1)
	_sim.air_accelerate(state, wish_dir, _sim.cfg.max_speed, 1.0 / 60.0)
	assert_almost_eq(state.velocity.z, vel_before, 0.001,
		"should not decelerate existing speed")


# --- gravity ---

func test_gravity_applied_airborne() -> void:
	var state := _make_state()
	state.on_floor = false
	var vel_before := state.velocity.y
	var cmd := _make_cmd()
	_sim.normal_movement(state, cmd)
	var expected := vel_before - _sim.cfg.gravity * cmd.delta
	assert_almost_eq(state.velocity.y, expected, 0.0001, "full-step gravity when airborne")


func test_gravity_respects_gravity_scale() -> void:
	var state := _make_state()
	state.on_floor = false
	state.gravity_scale = 0.0
	var vel_before := state.velocity.y
	var cmd := _make_cmd()
	_sim.normal_movement(state, cmd)
	assert_almost_eq(state.velocity.y, vel_before, 0.0001,
		"gravity_scale=0 means no gravity")


# --- get_max_speed ---

func test_get_max_speed_crouch() -> void:
	var state := _make_state()
	state.is_crouched = true
	var cmd := _make_cmd()
	var speed := _sim.get_max_speed(state, cmd)
	assert_almost_eq(speed, _sim.cfg.max_speed * _sim.cfg.duck_mult, 0.001, "crouch speed")


func test_get_max_speed_walk() -> void:
	var state := _make_state()
	var cmd := _make_cmd()
	cmd.walk = true
	var speed := _sim.get_max_speed(state, cmd)
	assert_almost_eq(speed, _sim.cfg.max_speed * _sim.cfg.walk_mult, 0.001, "walk speed")


func test_get_max_speed_speed_scale() -> void:
	var state := _make_state()
	state.speed_scale = 1.5
	var cmd := _make_cmd()
	var speed := _sim.get_max_speed(state, cmd)
	assert_almost_eq(speed, _sim.cfg.max_speed * 1.5, 0.001, "speed_scale")


func test_get_max_speed_stacks() -> void:
	var state := _make_state()
	state.is_crouched = true
	state.speed_scale = 2.0
	var cmd := _make_cmd()
	cmd.walk = true
	var speed := _sim.get_max_speed(state, cmd)
	var expected := _sim.cfg.max_speed * 2.0 * _sim.cfg.duck_mult * _sim.cfg.walk_mult
	assert_almost_eq(speed, expected, 0.001, "all modifiers stack")


# --- clamp_velocity ---

func test_clamp_velocity() -> void:
	# clamp_velocity is per-component (sv_maxvelocity), not vector-length — see
	# movement.gd. Each axis is clamped independently to ±max_velocity.
	var mv := _sim.cfg.max_velocity
	var state := _make_state(Vector3(mv + 100, mv + 100, -(mv + 100)))
	_sim.clamp_velocity(state)
	assert_almost_eq(state.velocity.x, mv, 0.001, "x clamped to +max_velocity")
	assert_almost_eq(state.velocity.y, mv, 0.001, "y clamped to +max_velocity")
	assert_almost_eq(state.velocity.z, -mv, 0.001, "z clamped to -max_velocity")


# --- is_move_locked ---

func test_is_move_locked_zeroes_velocity() -> void:
	var state := _make_state(Vector3(5, 3, -2))
	state.is_move_locked = true
	assert_true(state.is_move_locked, "is_move_locked flag should be set")


# --- calc_wish_dir ---

func test_calc_wish_forward() -> void:
	var cmd := _make_cmd(Vector2(0, 1))  # y=forward
	cmd.yaw = 0.0
	var wish_dir := Movement.calc_wish_dir(cmd)
	assert_gt(wish_dir.z, 0.5, "forward input at yaw=0 should be +Z")


func test_calc_wish_strafe() -> void:
	var cmd := _make_cmd(Vector2(1, 0))  # x=right
	cmd.yaw = 0.0
	var wish_dir := Movement.calc_wish_dir(cmd)
	assert_gt(wish_dir.x, 0.5, "right input at yaw=0 should be +X")


func test_calc_wish_no_input() -> void:
	var cmd := _make_cmd()
	var wish_dir := Movement.calc_wish_dir(cmd)
	assert_eq(wish_dir, Vector3.ZERO, "no input → zero wish")


# --- crouch: GoldSrc PM_Duck moves the origin, and which end moves depends on
# whether you are standing on something (see Simulation.update_crouch).

func _crouch_state(body: CrouchBody, on_floor: bool, crouched: bool) -> Movement.MovementState:
	var state := _make_state(Vector3.ZERO, on_floor)
	state._stand_height = _sim.cfg.stand_height
	state._crouch_height = _sim.cfg.crouch_height
	state.bind_body(body)
	state.position = Vector3(0, 10.0, 0)
	state.is_crouched = crouched
	return state


func test_duck_on_ground_keeps_feet_planted() -> void:
	var body := CrouchBody.new()
	var state := _crouch_state(body, true, false)
	var cmd := _make_cmd()
	cmd.crouch = true
	_sim.update_crouch(body, state, cmd)
	assert_true(state.is_crouched, "ducking on the ground crouches")
	assert_almost_eq(state.position.y, 10.0, 0.0001,
		"the origin is the feet, so a grounded duck must not move it")


func test_duck_in_air_lifts_the_feet() -> void:
	var body := CrouchBody.new()
	var state := _crouch_state(body, false, false)
	var cmd := _make_cmd()
	cmd.crouch = true
	_sim.update_crouch(body, state, cmd)
	var lift := (_sim.cfg.stand_height - _sim.cfg.crouch_height) * 0.5
	assert_almost_eq(state.position.y, 10.0 + lift, 0.0001,
		"ducking mid-air raises the feet by half the height change (the duck-jump)")


func test_unduck_in_air_drops_the_feet_back() -> void:
	var body := CrouchBody.new()
	var state := _crouch_state(body, false, true)
	var cmd := _make_cmd()
	_sim.update_crouch(body, state, cmd)
	var lift := (_sim.cfg.stand_height - _sim.cfg.crouch_height) * 0.5
	assert_false(state.is_crouched, "standing up mid-air with room")
	assert_almost_eq(state.position.y, 10.0 - lift, 0.0001,
		"standing up mid-air returns the feet to where the duck lifted them from")


func test_unduck_in_air_blocked_keeps_the_lift() -> void:
	var body := CrouchBody.new()
	var state := _crouch_state(body, false, true)
	body.uncrouch_ok = false
	var cmd := _make_cmd()
	_sim.update_crouch(body, state, cmd)
	assert_true(state.is_crouched, "no room to stand: stay crouched")
	assert_almost_eq(state.position.y, 10.0, 0.0001,
		"a refused stand-up must leave the position exactly where it was")


func test_restore_resyncs_the_hull_to_the_restored_crouch() -> void:
	# A correction that flips is_crouched is not a crouch transition, so update_crouch
	# never fires — the hull has to follow from the assignment itself.
	var body := CrouchBody.new()
	var state := _crouch_state(body, true, false)
	body.height = _sim.cfg.stand_height       # the scene ships the standing capsule

	state.restore({
		"position": Vector3.ZERO, "velocity": Vector3.ZERO,
		"is_crouched": true, "is_jumping": false, "on_floor": true,
	})
	assert_almost_eq(body.height, _sim.cfg.crouch_height, 0.0001,
		"restoring a crouched snapshot must shrink the hull, not just the flag")

	state.restore({
		"position": Vector3.ZERO, "velocity": Vector3.ZERO,
		"is_crouched": false, "is_jumping": false, "on_floor": true,
	})
	assert_almost_eq(body.height, _sim.cfg.stand_height, 0.0001,
		"and restoring a standing snapshot must grow it back")
