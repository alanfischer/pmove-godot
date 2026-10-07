extends "res://tests/suite.gd"

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const PredictionBuffer = preload("res://addons/pmove/prediction_buffer.gd")
const ClientMovementClass = preload("res://addons/pmove/client_movement.gd")


## Mock body: flat ground at y=0, no walls. Enough for simulate_tick.
class StubBody:
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var yaw := 0.0
	var _delta := 1.0 / 60.0

	func move_and_slide() -> bool:
		global_position += velocity * _delta
		if global_position.y <= 0.0:
			global_position.y = 0.0
			if velocity.y < 0.0:
				velocity.y = 0.0
		return velocity.length() > 0.001

	func move_and_collide(_motion: Vector3, _test_only := false, _margin := 0.001):
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


func _make_cmd(seq: int, move := Vector2.ZERO) -> InputCommand:
	var cmd := InputCommand.new()
	cmd.seq = seq
	cmd.delta = 1.0 / 60.0
	cmd.move_input = move
	return cmd


func _server(seq: int, pos := Vector3.ZERO, vel := Vector3.ZERO,
		crouched := false, on_floor := true, jumping := false) -> ClientMovementClass.ServerState:
	return ClientMovementClass.ServerState.new(seq, pos, vel, crouched, on_floor, jumping)


func _run_tests() -> void:
	_run_method("test_seq_increments")
	_run_method("test_predict_records_to_buffer")
	_run_method("test_predict_calls_modifier")
	_run_method("test_predict_syncs_body_to_state")
	_run_method("test_buffer_overflow_prunes_old")
	_run_method("test_reconcile_match_no_correction")
	_run_method("test_reconcile_mismatch_snaps_and_replays")
	_run_method("test_reconcile_below_threshold_no_correction")
	_run_method("test_reconcile_above_threshold_corrects")
	_run_method("test_reconcile_exact_match_no_correction")
	_run_method("test_reconcile_stale_seq")
	_run_method("test_reconcile_prunes_old_entries")
	_run_method("test_reconcile_uses_stored_modifier_during_replay")
	_run_method("test_clear_resets_buffer")


func test_seq_increments() -> void:
	var cm := ClientMovementClass.new()
	assert_eq(cm.get_next_seq(), 1, "first seq")
	assert_eq(cm.get_next_seq(), 2, "second seq")
	assert_eq(cm.get_next_seq(), 3, "third seq")


func test_predict_records_to_buffer() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	for i in 5:
		var cmd := _make_cmd(cm.get_next_seq())
		cm.predict(body, cmd)
	assert_eq(cm.buffer_size(), 5, "5 predictions recorded")


func test_predict_calls_modifier() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	var counts := [0]
	var modifier_cb := func(_cmd) -> Movement.MovementModifiers:
		counts[0] += 1
		return Movement.MovementModifiers.new()

	for i in 3:
		cm.predict(body, _make_cmd(cm.get_next_seq()), modifier_cb)
	assert_eq(counts[0], 3, "modifier called once per predict")


func test_predict_syncs_body_to_state() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	body.global_position = Vector3(5, 0, 3)
	body.velocity = Vector3(1, 0, 0)
	cm.predict(body, _make_cmd(cm.get_next_seq()))
	assert_vec3_almost_eq(cm.state.position, body.global_position, 0.1,
		"state tracks body after predict")


func test_buffer_overflow_prunes_old() -> void:
	# The cap belongs to the harness, not to ClientMovement — so this reaches it through an
	# injected buffer, which is also the seam a game with its own input history would use.
	var buffer := PredictionBuffer.new()
	buffer.max_buffer = 8
	var cm := ClientMovementClass.new(null, buffer)
	var body := StubBody.new()
	for i in buffer.max_buffer + 20:
		cm.predict(body, _make_cmd(cm.get_next_seq()))
	assert_eq(cm.buffer_size(), buffer.max_buffer,
		"the unacked buffer is capped by the harness it was given")


## The sequence counter lives on ClientMovement rather than on the buffer, because the rule it
## obeys is a movement one: it must keep climbing across clear(), or the server discards the
## first commands after a respawn as duplicates of the pre-death ones and the player is stuck.
func test_seq_is_monotonic() -> void:
	var cm := ClientMovementClass.new()
	assert_eq(cm.last_seq(), 0, "last_seq() is 0 before the first command")
	assert_eq(cm.get_next_seq(), 1, "sequences start at 1")
	assert_eq(cm.get_next_seq(), 2, "sequences increment")
	assert_eq(cm.get_next_seq(), 3, "sequences keep incrementing")
	assert_eq(cm.last_seq(), 3, "last_seq() is the most recently handed-out id")


func test_clear_keeps_climbing_the_seq() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	for i in 3:
		cm.predict(body, _make_cmd(cm.get_next_seq()))
	cm.clear()
	assert_eq(cm.buffer_size(), 0, "clear() drops the unacked history")
	assert_eq(cm.get_next_seq(), 4, "clear() does NOT reset the sequence counter")


func test_reconcile_match_no_correction() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	body.global_position = Vector3(5, 0, 3)
	for i in 5:
		cm.predict(body, _make_cmd(cm.get_next_seq()))
	# Server agrees with our prediction at seq 3
	var corrected := cm.reconcile(body, _server(3, cm.state.position))
	assert_false(corrected, "no correction when prediction matches")


func test_reconcile_mismatch_snaps_and_replays() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	for i in 5:
		cm.predict(body, _make_cmd(cm.get_next_seq()))

	var server_pos := Vector3(10, 0, 0)
	var corrected := cm.reconcile(body, _server(3, server_pos, Vector3.ZERO))
	assert_true(corrected, "should correct on mismatch")
	# Snapped to server, then replayed cmds 4 and 5 with zero velocity
	assert_vec3_almost_eq(cm.state.position, server_pos, 0.01, "position after replay")


## Sub-threshold mismatches (< 5mm) are suppressed. They're dominated by replay
## non-determinism: N move_and_slide calls in one frame vs one per frame on the
## server produce ~0.5mm of noise. Correcting on that noise fires chain
## corrections that amplify the error instead of fixing it.
func test_reconcile_below_threshold_no_correction() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	var pos := Vector3(10, 0, 5)
	body.global_position = pos
	cm.predict(body, _make_cmd(cm.get_next_seq()))

	# 3mm offset — below the 5mm threshold.
	var server_pos := cm.state.position + Vector3(0.003, 0, 0)
	var corrected := cm.reconcile(body, _server(1, server_pos))
	assert_false(corrected, "sub-threshold mismatch must not correct")


## Mismatches above the 5mm threshold are real divergence and must correct.
func test_reconcile_above_threshold_corrects() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	var pos := Vector3(10, 0, 5)
	body.global_position = pos
	cm.predict(body, _make_cmd(cm.get_next_seq()))

	# 10mm offset — above the 5mm threshold.
	var server_pos := cm.state.position + Vector3(0.010, 0, 0)
	var corrected := cm.reconcile(body, _server(1, server_pos))
	assert_true(corrected, "above-threshold mismatch must correct")


## Only exact float equality suppresses a correction.
func test_reconcile_exact_match_no_correction() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	var pos := Vector3(10, 0, 5)
	body.global_position = pos
	cm.predict(body, _make_cmd(cm.get_next_seq()))

	# Server position identical to snapshot — no correction.
	var corrected := cm.reconcile(body, _server(1, cm.state.position))
	assert_false(corrected, "exact position match must not correct")


func test_reconcile_stale_seq() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	for i in 10:
		cm.predict(body, _make_cmd(cm.get_next_seq()))
	var corrected := cm.reconcile(body, _server(0))
	assert_false(corrected, "stale seq should be ignored")


func test_reconcile_prunes_old_entries() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	for i in 10:
		body.global_position = Vector3(float(i + 1), 0, 0)
		cm.predict(body, _make_cmd(cm.get_next_seq()))

	cm.reconcile(body, _server(7, Vector3(7, 0, 0)))
	assert_eq(cm.buffer_size(), 3, "old entries pruned after reconcile")


## Reconcile replay is fully data-driven from the MovementModifiers captured at
## predict time — no live callback runs during replay. We verify that by
## predicting with is_move_locked=true (which makes simulate_tick a no-op) and
## then forcing a correction. If the stored modifier is honoured during replay,
## body stays exactly at the server position. If replay fell back to a default
## modifier, simulate_tick would run normal movement and the body would drift.
func test_reconcile_uses_stored_modifier_during_replay() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	var modifier_cb := func(_cmd) -> Movement.MovementModifiers:
		var m := Movement.MovementModifiers.new()
		m.is_move_locked = true
		return m

	# Predict 5 locked ticks while "trying" to move forward — no motion happens.
	for i in 5:
		var cmd := _make_cmd(cm.get_next_seq())
		cmd.move_input = Vector2(0, -1)
		cm.predict(body, cmd, modifier_cb)

	# Force a correction at seq 2 → snap to server_pos, replay seqs 3-5.
	# With stored modifiers (is_move_locked), replay must not move the body.
	var server_pos := Vector3(5, 0, 0)
	cm.reconcile(body, _server(2, server_pos, Vector3.ZERO))
	assert_vec3_almost_eq(body.global_position, server_pos, 0.001,
		"stored is_move_locked modifier must prevent replay motion")


func test_clear_resets_buffer() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	for i in 5:
		cm.predict(body, _make_cmd(cm.get_next_seq()))
	assert_eq(cm.buffer_size(), 5, "before clear")
	cm.clear()
	assert_eq(cm.buffer_size(), 0, "after clear")
