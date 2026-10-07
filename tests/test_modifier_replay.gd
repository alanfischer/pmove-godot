extends "res://tests/suite.gd"

## Tests that reconciliation replays use per-tick stored modifiers instead of
## current modifier state. This prevents rubber-banding when gravity_scale (or
## other modifiers) change mid-prediction — e.g. the levitate spell on a laggy
## client.

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")

# Loaded by path, not by the global class name: the class registry comes from a cache the
# editor writes during an import pass, which a bare `--headless --path` run does not perform,
# so a clean checkout has no registry at all. The classes keep their class_name for
# consumers; the suites just cannot rely on it.
const ClientMovementClass = preload("res://addons/pmove/client_movement.gd")

const TICK_DELTA := 1.0 / 60.0


class StubBody:
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
	func move_and_collide(_motion: Vector3, _test_only := false, _margin := 0.001):
		return null
	func is_on_floor() -> bool:
		return global_position.y <= 0.001
	func apply_floor_snap() -> void: pass
	func set_collision_height(_h: float, _c: float) -> void:
		pass
	func has_headroom(_rise: float, _from_offset := Vector3.ZERO) -> bool:
		return true


func _make_cmd(seq: int) -> InputCommand:
	var cmd := InputCommand.new()
	cmd.seq = seq
	cmd.delta = TICK_DELTA
	cmd.move_input = Vector2.ZERO
	return cmd


func _run_tests() -> void:
	_run_method("test_gravity_change_replayed_correctly")
	_run_method("test_stored_modifiers_provide_baseline_during_replay")
	_run_method("test_speed_scale_change_replayed_correctly")


## Core test: client predicts 10 ticks at gravity 1.0, then 10 ticks at gravity
## 0.1 (levitate). Server ack arrives for tick 5 with a small position offset.
## Reconciliation must replay ticks 6-10 with gravity=1.0 and ticks 11-20 with
## gravity=0.1 — NOT use the current gravity (0.1) for all 15 replayed ticks.
func test_gravity_change_replayed_correctly() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	body.global_position = Vector3(0, 10, 0)  # start in the air
	body.velocity = Vector3.ZERO

	var gravity_scale := 1.0

	var modifier_cb := func(_cmd) -> Movement.MovementModifiers:
		var m := Movement.MovementModifiers.new()
		m.gravity_scale = gravity_scale
		return m

	for i in 10:
		cm.predict(body, _make_cmd(cm.get_next_seq()), modifier_cb)

	var pos_at_tick_10 := Vector3(body.global_position)

	gravity_scale = 0.1

	for i in 10:
		cm.predict(body, _make_cmd(cm.get_next_seq()), modifier_cb)

	var expected_pos := Vector3(body.global_position)

	# Server ack for tick 5 with a small nudge triggers reconciliation + replay of 6-20.
	var server_nudge := Vector3(0.05, 0, 0)
	# Re-simulate 5 ticks from the same start to get the position the client
	# predicted at tick 5 (can't read it back out of the buffer directly).
	var ref_body := StubBody.new()
	ref_body.global_position = Vector3(0, 10, 0)
	ref_body.velocity = Vector3.ZERO
	var ref_cm := ClientMovementClass.new()
	var ref_cb := func(_cmd) -> Movement.MovementModifiers:
		var m := Movement.MovementModifiers.new()
		m.gravity_scale = 1.0
		return m
	for i in 5:
		ref_cm.predict(ref_body, _make_cmd(ref_cm.get_next_seq()), ref_cb)
	var server_pos := ref_body.global_position + server_nudge

	# Reconcile — stored modifiers override per-tick during replay; no callback needed.
	var corrected := cm.reconcile(body, ClientMovementClass.ServerState.new(
		5, server_pos, ref_cm.state.velocity, false, false, false))
	assert_true(corrected, "should correct due to server nudge")

	# The replayed position should be very close to expected + the server nudge.
	# The X offset propagates through (no X movement), Y should match because
	# gravity was replayed with correct per-tick values.
	var replayed_pos := body.global_position

	# Y position is the critical check — if reconciliation used current gravity
	# (0.1) for ALL 15 replayed ticks, the player would fall much less than
	# expected and end up too high.
	var y_tolerance := 0.15
	assert_almost_eq(replayed_pos.y, expected_pos.y + server_nudge.y, y_tolerance,
		"Y must match per-tick gravity replay (not current gravity for all)")

	# Control: what if replay used current gravity (0.1) for all 15 ticks instead?
	var wrong_body := StubBody.new()
	wrong_body.global_position = server_pos
	wrong_body.velocity = ref_cm.state.velocity
	var wrong_cm := ClientMovementClass.new()
	var wrong_cb := func(_cmd) -> Movement.MovementModifiers:
		var m := Movement.MovementModifiers.new()
		m.gravity_scale = 0.1  # wrong: uses current gravity for all
		return m
	for i in 15:
		wrong_cm.predict(wrong_body, _make_cmd(wrong_cm.get_next_seq()), wrong_cb)
	var wrong_pos := wrong_body.global_position

	# The wrong replay should produce a significantly different Y (much higher,
	# since low gravity means less falling)
	var y_diff := absf(wrong_pos.y - replayed_pos.y)
	assert_gt(y_diff, 0.5,
		"wrong (uniform gravity) replay must differ significantly from correct replay (diff=%.3f)" % y_diff)


## Verify that stored modifiers provide authoritative state during replay.
## Reconcile replay is data-driven from stored MovementModifiers with no live
## callback — stored gravity_scale must be applied even without a reconcile callback.
func test_stored_modifiers_provide_baseline_during_replay() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	body.global_position = Vector3(0, 50, 0)  # high up so gravity has room

	# Predict with gravity=1.0
	var modifier_cb := func(_cmd) -> Movement.MovementModifiers:
		var m := Movement.MovementModifiers.new()
		m.gravity_scale = 1.0
		return m
	for i in 30:
		cm.predict(body, _make_cmd(cm.get_next_seq()), modifier_cb)

	var expected_pos := Vector3(body.global_position)

	# Server agrees exactly at tick 1, but we force mismatch with a nudge.
	# Stored modifiers should set gravity_scale = 1.0 for each replayed tick.
	var ref_body := StubBody.new()
	ref_body.global_position = Vector3(0, 50, 0)
	var ref_cm := ClientMovementClass.new()
	ref_cm.predict(ref_body, _make_cmd(ref_cm.get_next_seq()), modifier_cb)
	var server_pos := ref_body.global_position + Vector3(0.05, 0, 0)

	cm.reconcile(body, ClientMovementClass.ServerState.new(
		1, server_pos, ref_cm.state.velocity, false, false, false))

	# Stored modifiers set gravity_scale=1.0, so the player should have fallen
	assert_almost_eq(body.global_position.y, expected_pos.y, 0.15,
		"stored modifiers should provide gravity baseline during replay")
	# Specifically, Y should be well below starting height due to gravity
	assert_lt(body.global_position.y, 48.0,
		"must have fallen due to stored gravity=1.0")


## Same idea as gravity test but for speed_scale — modifiers are replayed per-tick.
func test_speed_scale_change_replayed_correctly() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()

	var speed_scale := 1.0
	var modifier_cb := func(_cmd) -> Movement.MovementModifiers:
		var m := Movement.MovementModifiers.new()
		m.speed_scale = speed_scale
		return m

	# Predict 5 ticks at normal speed, moving forward
	for i in 5:
		var cmd := _make_cmd(cm.get_next_seq())
		cmd.move_input = Vector2(0, -1)  # forward
		cm.predict(body, cmd, modifier_cb)

	# Change speed
	speed_scale = 0.5
	for i in 5:
		var cmd := _make_cmd(cm.get_next_seq())
		cmd.move_input = Vector2(0, -1)
		cm.predict(body, cmd, modifier_cb)

	var expected_pos := Vector3(body.global_position)

	# Force reconciliation at tick 3
	var ref_body := StubBody.new()
	var ref_cm := ClientMovementClass.new()
	var ref_cb := func(_cmd) -> Movement.MovementModifiers:
		var m := Movement.MovementModifiers.new()
		m.speed_scale = 1.0
		return m
	for i in 3:
		var cmd := _make_cmd(ref_cm.get_next_seq())
		cmd.move_input = Vector2(0, -1)
		ref_cm.predict(ref_body, cmd, ref_cb)
	var server_pos := ref_body.global_position + Vector3(0.05, 0, 0)

	cm.reconcile(body, ClientMovementClass.ServerState.new(
		3, server_pos, ref_cm.state.velocity, false, true, false))

	# Z position should be close to expected (speed changed mid-stream)
	assert_almost_eq(body.global_position.z, expected_pos.z, 0.15,
		"Z must reflect per-tick speed_scale replay")
