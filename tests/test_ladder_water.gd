extends "res://tests/suite.gd"
## Ladders and water: the moves, and the Driver's choice between them.

const Movement = preload("res://addons/pmove/movement.gd")
const LadderWater = preload("res://addons/pmove/ladder_water.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")

const FACING_NORTH := 0.0           # yaw 0 looks down -z
const LADDER_NORMAL := Vector3(0, 0, 1)  # a ladder on a wall to the north, facing the climber

var _cfg := MovementConfig.new()


func _cmd(move := Vector2.ZERO, jump := false, pitch := 0.0) -> InputCommand:
	var cmd := InputCommand.new()
	cmd.move_input = move
	cmd.yaw = FACING_NORTH
	cmd.pitch = pitch
	cmd.jump = jump
	cmd.delta = 1.0 / 60.0
	return cmd


func _space() -> PhysicsDirectSpaceState3D:
	return _root().get_viewport().world_3d.direct_space_state


func test_forward_on_a_ladder_climbs() -> void:
	var v := LadderWater.ladder_velocity(_cfg, false, false, _cmd(Vector2(0, -1)), LADDER_NORMAL)
	assert_almost_eq(v.y, _cfg.ladder_speed, 0.01, "pressing into the ladder climbs at ladder_speed")
	assert_almost_eq(v.z, 0.0, 0.01, "and does not push into the wall")


func test_back_on_a_ladder_descends() -> void:
	var v := LadderWater.ladder_velocity(_cfg, false, false, _cmd(Vector2(0, 1)), LADDER_NORMAL)
	assert_lt(v.y, -_cfg.ladder_speed * 0.99, "pulling away from it climbs down")


func test_no_input_holds_on_a_ladder() -> void:
	assert_eq(LadderWater.ladder_velocity(_cfg, false, false, _cmd(), LADDER_NORMAL), Vector3.ZERO,
		"a climber with no input stays put")


func test_jump_pushes_off_a_ladder() -> void:
	var mods := Movement.MovementModifiers.new()
	var driver := LadderWater.Driver.new()
	driver.apply(mods, _cfg, Movement.MovementState.new(), _cmd(Vector2.ZERO, true), true,
			LADDER_NORMAL, false, null)
	assert_true(mods.velocity_override_active, "a ladder overrides the move")
	assert_almost_eq(mods.override_velocity.z, _cfg.ladder_jump, 0.01, "jump pushes away from it")


func test_a_fast_body_is_knocked_off_the_ladder() -> void:
	var mods := Movement.MovementModifiers.new()
	var driver := LadderWater.Driver.new()
	driver.ladder_knockoff_speed = 10.0
	var state := Movement.MovementState.new()
	state.velocity = Vector3(12, 0, 0)
	driver.apply(mods, _cfg, state, _cmd(Vector2(0, -1)), true, LADDER_NORMAL, false, null)
	assert_false(mods.velocity_override_active, "past knockoff speed the ladder lets go")


func test_holding_jump_swims_up() -> void:
	var mods := Movement.MovementModifiers.new()
	LadderWater.Driver.new().apply(mods, _cfg, Movement.MovementState.new(),
			_cmd(Vector2.ZERO, true), false, Vector3.ZERO, true, null)
	assert_true(mods.velocity_override_active, "water overrides the move")
	assert_gt(mods.override_velocity.y, 0.0, "jump held rises")


func test_water_drags() -> void:
	var v := LadderWater.swim(_cfg, Vector3(5, 0, 0), Vector3.ZERO, 0.1)
	assert_almost_eq(v.x, 5.0 * (1.0 - _cfg.water_friction * 0.1), 0.001,
		"with no wish, speed drops by water_friction")


func _bank(top_y: float) -> void:
	# A wall 0.5 m north of the origin, standing from -2 to top_y.
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, top_y + 2.0, 1)
	cs.shape = box
	sb.add_child(cs)
	sb.position = Vector3(0, (top_y - 2.0) * 0.5, -1.0)
	_root().add_child(_keep(sb))


func test_swimming_at_a_low_bank_climbs_out() -> void:
	_bank(1.2)
	var driver := LadderWater.Driver.new()
	var mods := Movement.MovementModifiers.new()
	driver.apply(mods, _cfg, Movement.MovementState.new(), _cmd(Vector2(0, -1)), false,
			Vector3.ZERO, true, _space())
	assert_almost_eq(mods.override_velocity.y, LadderWater.WATERJUMP_UP, 0.01, "a lip in reach launches")
	assert_almost_eq(driver.waterjump_time, LadderWater.WATERJUMP_TIME, 0.001, "and starts the clock")

	# The next tick, still in the water: air movement carries it, and jump is not handled.
	mods = Movement.MovementModifiers.new()
	driver.apply(mods, _cfg, Movement.MovementState.new(), _cmd(Vector2(0, -1), true), false,
			Vector3.ZERO, true, _space())
	assert_false(mods.velocity_override_active, "mid-launch, the swim lets go")
	assert_true(mods.skip_jump, "and the jump button is ignored")


func test_a_wall_too_tall_is_not_a_bank() -> void:
	_bank(4.0)
	var mods := Movement.MovementModifiers.new()
	LadderWater.Driver.new().apply(mods, _cfg, Movement.MovementState.new(), _cmd(Vector2(0, -1)),
			false, Vector3.ZERO, true, _space())
	assert_true(mods.override_velocity.y < LadderWater.WATERJUMP_UP - 1.0,
		"a cliff is swum against, not launched up")


func test_a_skipped_jump_neither_jumps_nor_latches() -> void:
	var sim := Movement.Simulation.new(_cfg)
	var state := Movement.MovementState.new()
	state.on_floor = true
	var mods := Movement.MovementModifiers.new()
	mods.skip_jump = true
	mods.apply_to(state)
	sim.simulate_tick(FloorBody.new(), state, _cmd(Vector2.ZERO, true))
	assert_false(state.is_jumping, "no jump on a skipped tick")
	assert_false(state.jump_held, "and still holding on the next tick is a fresh press")


class FloorBody:
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var yaw := 0.0

	func move_and_slide() -> bool:
		global_position += velocity * (1.0 / 60.0)
		global_position.y = maxf(global_position.y, 0.0)
		return false

	func move_and_collide(motion: Vector3, _test_only := false, _margin := 0.001):
		global_position += motion
		global_position.y = maxf(global_position.y, 0.0)
		return null

	func is_on_floor() -> bool: return global_position.y <= 0.001
	func apply_floor_snap() -> void: global_position.y = 0.0
	func set_collision_height(_h: float, _c: float) -> void: pass
	func has_headroom(_rise: float, _from_offset := Vector3.ZERO) -> bool: return true
