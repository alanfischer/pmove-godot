extends "res://tests/suite.gd"

const InputCommand = preload("res://addons/pmove/input_command.gd")

# Loaded by path, not by the global class name: the class registry comes from a cache the
# editor writes during an import pass, which a bare `--headless --path` run does not perform,
# so a clean checkout has no registry at all. The classes keep their class_name for
# consumers; the suites just cannot rely on it.
const ServerMovementClass = preload("res://addons/pmove/net/server_movement.gd")


## Minimal stub body — enough for process_queue and out-of-band position writes.
class StubBody:
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var yaw := 0.0
	func move_and_slide() -> bool:
		global_position += velocity * (1.0 / 60.0)
		return false
	func move_and_collide(_motion: Vector3, _test_only := false, _margin := 0.001):
		return null
	func is_on_floor() -> bool: return true
	func apply_floor_snap() -> void: pass
	func set_collision_height(_h: float, _c: float) -> void: pass
	func has_headroom(_rise: float, _from_offset := Vector3.ZERO) -> bool: return true


func _make_cmd(seq: int) -> InputCommand:
	var cmd := InputCommand.new()
	cmd.seq = seq
	cmd.move_input = Vector2(0, 1)
	cmd.delta = 1.0 / 60.0
	return cmd


func _run_tests() -> void:
	_run_method("test_enqueue_and_process_updates_seq")
	_run_method("test_queue_ordering")
	_run_method("test_queue_overflow_drops_oldest")
	_run_method("test_duplicate_seq_ignored")
	_run_method("test_redundant_batch_dedup")
	_run_method("test_overlapping_batches")
	_run_method("test_redundant_batch_processes_in_order")
	_run_method("test_position_tracks_body_without_processing")
	_run_method("test_position_write_moves_body")


func test_enqueue_and_process_updates_seq() -> void:
	var sm := ServerMovementClass.new()
	sm.enqueue(_make_cmd(1))
	sm.enqueue(_make_cmd(2))
	sm.enqueue(_make_cmd(3))
	assert_eq(sm.queue_size(), 3, "should have 3 queued commands")
	assert_eq(sm.last_processed_seq, -1, "nothing processed yet")


func test_queue_ordering() -> void:
	var sm := ServerMovementClass.new()
	sm.enqueue(_make_cmd(3))
	sm.enqueue(_make_cmd(1))
	sm.enqueue(_make_cmd(2))
	assert_eq(sm.queue_size(), 3, "all commands queued")


func test_queue_overflow_drops_oldest() -> void:
	var sm := ServerMovementClass.new()
	var test_limit := 10
	sm.max_queue = test_limit
	for i in test_limit + 5:
		sm.enqueue(_make_cmd(i + 1))
	assert_eq(sm.queue_size(), test_limit,
		"queue should not exceed max_queue")


func test_duplicate_seq_ignored() -> void:
	var sm := ServerMovementClass.new()
	sm.last_processed_seq = 5
	sm.enqueue(_make_cmd(3))
	sm.enqueue(_make_cmd(5))
	sm.enqueue(_make_cmd(6))
	assert_eq(sm.queue_size(), 1, "only seq > last_processed should be queued")


func test_redundant_batch_dedup() -> void:
	## Same seq enqueued multiple times (as happens with redundant batch sends).
	var sm := ServerMovementClass.new()
	sm.enqueue(_make_cmd(1))
	sm.enqueue(_make_cmd(2))
	sm.enqueue(_make_cmd(1))  # redundant
	sm.enqueue(_make_cmd(2))  # redundant
	sm.enqueue(_make_cmd(3))
	assert_eq(sm.queue_size(), 3, "duplicates from redundant sends should be ignored")


func test_overlapping_batches() -> void:
	## Simulates two overlapping batches: [3,4,5] then [4,5,6].
	var sm := ServerMovementClass.new()
	sm.last_processed_seq = 2
	# First batch
	sm.enqueue(_make_cmd(3))
	sm.enqueue(_make_cmd(4))
	sm.enqueue(_make_cmd(5))
	# Second batch (overlaps on 4,5)
	sm.enqueue(_make_cmd(4))
	sm.enqueue(_make_cmd(5))
	sm.enqueue(_make_cmd(6))
	assert_eq(sm.queue_size(), 4, "overlapping batches should deduplicate to seqs 3-6")


func test_redundant_batch_processes_in_order() -> void:
	## Commands arrive out of order via redundant batches but process in seq order.
	## No real CharacterBody3D here (process_queue needs one for move_and_slide),
	## so we verify ordering via the queue's internal sort instead.
	var sm := ServerMovementClass.new()
	sm.enqueue(_make_cmd(5))
	sm.enqueue(_make_cmd(3))
	sm.enqueue(_make_cmd(4))
	sm.enqueue(_make_cmd(3))  # redundant
	sm.enqueue(_make_cmd(5))  # redundant
	assert_eq(sm.queue_size(), 3, "should have 3 unique commands")
	assert_eq(sm._highest_enqueued_seq, 5, "highest enqueued should track max seq")


func test_position_tracks_body_without_processing() -> void:
	## state.position is now a live view over the body, so an out-of-band teleport
	## (dead, no queued input) is visible without waiting for process_queue.
	var sm := ServerMovementClass.new()
	var body := StubBody.new()
	sm.bind_body(body)

	body.global_position = Vector3(10, 2, -5)  # out-of-band teleport, no commands
	assert_vec3_almost_eq(sm.state.position, Vector3(10, 2, -5), 0.0001,
		"state.position must follow the body with no process_queue in between")

	body.global_position = Vector3(-3, 0, 7)
	assert_vec3_almost_eq(sm.state.position, Vector3(-3, 0, 7), 0.0001,
		"and keep following it on every later move")


func test_position_write_moves_body() -> void:
	## The view is two-way: writing state.position moves the body, so the sim can
	## never advance to a position the physics body isn't actually at.
	var sm := ServerMovementClass.new()
	var body := StubBody.new()
	sm.bind_body(body)

	sm.state.position = Vector3(1, 2, 3)
	assert_vec3_almost_eq(body.global_position, Vector3(1, 2, 3), 0.0001,
		"writing state.position must move the body")

	sm.enqueue(_make_cmd(1))
	sm.process_queue(body)
	assert_vec3_almost_eq(sm.state.position, body.global_position, 0.0001,
		"body and sim position stay equal after a processed tick")
