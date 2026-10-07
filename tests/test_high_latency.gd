extends "res://tests/suite.gd"

## Tests that network buffers handle 500ms round-trip latency.
## At 60Hz, 500ms one-way ~ 30 commands in flight simultaneously.

const InputCommand = preload("res://addons/pmove/input_command.gd")

# Loaded by path, not by the global class name: the class registry comes from a cache the
# editor writes during an import pass, which a bare `--headless --path` run does not perform,
# so a clean checkout has no registry at all. The classes keep their class_name for
# consumers; the suites just cannot rely on it.
const ServerMovementClass = preload("res://addons/pmove/net/server_movement.gd")
const ClientMovementClass = preload("res://addons/pmove/net/client_movement.gd")

const TICK_DELTA := 1.0 / 60.0
# 500ms round-trip -> 250ms one-way -> ~15 ticks of commands arrive per burst.
# Server processes once per tick, so two bursts (worst case) ~ 30 commands.
const LATENCY_TICKS := 30


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


func _make_cmd(seq: int, move := Vector2(0, -1)) -> InputCommand:
	var cmd := InputCommand.new()
	cmd.seq = seq
	cmd.move_input = move
	cmd.yaw = 0.0
	cmd.delta = TICK_DELTA
	return cmd


func _run_tests() -> void:
	_run_method("test_server_queue_holds_500ms_burst")
	_run_method("test_client_holds_unacked_across_500ms")
	_run_method("test_reconcile_with_stale_server_ack")


## Server receives a 500ms burst of commands at once -- none should be dropped.
func test_server_queue_holds_500ms_burst() -> void:
	var sm := ServerMovementClass.new()
	for i in LATENCY_TICKS:
		sm.enqueue(_make_cmd(i + 1))
	assert_eq(sm.queue_size(), LATENCY_TICKS,
		"server queue must hold %d commands (500ms burst)" % LATENCY_TICKS)


## Client predicts for 500ms with no server response.
## All entries must be retained for later reconciliation.
func test_client_holds_unacked_across_500ms() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	# Record the position after the first predict (simulate_tick alters it)
	cm.predict(body, _make_cmd(cm.get_next_seq()))
	var first_pos := cm.state.position
	var first_vel := cm.state.velocity
	for i in range(1, LATENCY_TICKS):
		cm.predict(body, _make_cmd(cm.get_next_seq()))
	assert_eq(cm.buffer_size(), LATENCY_TICKS,
		"must retain all %d unacked predictions" % LATENCY_TICKS)
	# Server acks seq 1 with the exact position we predicted
	var corrected := cm.reconcile(body,
		ClientMovementClass.ServerState.new(1, first_pos, first_vel, false, true))
	assert_false(corrected, "matching ack should reconcile cleanly")
	assert_eq(cm.buffer_size(), LATENCY_TICKS - 1,
		"reconcile should prune acked entry, keep the rest")


## Server ack arrives 30 ticks late. Client has predicted 1..60,
## server acks seq 30 with a different position -> must correct and replay.
func test_reconcile_with_stale_server_ack() -> void:
	var cm := ClientMovementClass.new()
	var body := StubBody.new()
	var total_ticks := LATENCY_TICKS * 2  # 60 ticks in flight
	for i in total_ticks:
		body.global_position = Vector3(float(i + 1), 0, 0)
		cm.predict(body, _make_cmd(cm.get_next_seq()))
	assert_eq(cm.buffer_size(), total_ticks, "all predictions recorded")

	# Server ack for seq 30 with a corrected position
	var server_pos := Vector3(999, 0, 0)
	var corrected := cm.reconcile(body,
		ClientMovementClass.ServerState.new(LATENCY_TICKS, server_pos, Vector3.ZERO, false, true))
	assert_true(corrected, "mismatch should trigger correction")
	# After correction, buffer should retain only cmds after seq 30
	assert_eq(cm.buffer_size(), LATENCY_TICKS,
		"must retain %d unacked predictions after reconcile" % LATENCY_TICKS)
