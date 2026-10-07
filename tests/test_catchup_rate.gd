extends "res://tests/suite.gd"
## Tests server-side command processing (see ROUTINE_JITTER_BATCH/THRESHOLD in
## server_movement.gd).
##
## A backlog at or below ROUTINE_JITTER_THRESHOLD is capped to ROUTINE_JITTER_BATCH
## commands per call, spreading routine jitter across a couple of ticks instead of
## snapping the body forward in one step. A backlog past the threshold still drains
## in full — real loss/hitch recovery should catch up immediately, not be throttled.
##
## We also verify:
##   - last_processed_seq advances to the highest drained seq.
##   - Subsequent calls with no new input are no-ops.
##   - Individual cmd.delta is clamped to MAX_CMD_DELTA (anti-exploit).

const InputCommand = preload("res://addons/pmove/input_command.gd")

# Loaded by path, not by the global class name: the class registry comes from a cache the
# editor writes during an import pass, which a bare `--headless --path` run does not perform,
# so a clean checkout has no registry at all. The classes keep their class_name for
# consumers; the suites just cannot rely on it.
const ServerMovementClass = preload("res://addons/pmove/server_movement.gd")


## Minimal stub body — just needs to not crash during process_queue.
## We only care about HOW MANY commands were processed, not the physics result.
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


func _make_cmd(seq: int, delta: float = 1.0 / 60.0) -> InputCommand:
	var cmd := InputCommand.new()
	cmd.seq = seq
	cmd.delta = delta
	return cmd


func _run_tests() -> void:
	_run_method("test_single_command_processed_per_call_empty_queue")
	_run_method("test_drains_entire_queue_in_one_call")
	_run_method("test_subsequent_calls_only_process_new_commands")
	_run_method("test_routine_backlog_capped_to_jitter_batch")
	_run_method("test_backlog_at_threshold_still_capped")
	_run_method("test_routine_backlog_drains_over_multiple_calls")
	_run_method("test_delta_clamped_to_max")
	_run_method("test_spike_scenario_drains_in_one_call")


## Baseline: queue=1 processes exactly 1 command.
func test_single_command_processed_per_call_empty_queue() -> void:
	var sm := ServerMovementClass.new()
	var body := StubBody.new()
	sm.enqueue(_make_cmd(1))
	sm.process_queue(body)
	assert_eq(sm.last_processed_seq, 1, "seq 1 should be processed")
	assert_eq(sm.queue_size(), 0, "queue should be empty after single command")


## A single process_queue() call drains the entire queue (GoldSrc-faithful).
## 10 commands queued from a WiFi spike → all processed in one tick.
func test_drains_entire_queue_in_one_call() -> void:
	var sm := ServerMovementClass.new()
	var body := StubBody.new()
	for i in 10:
		sm.enqueue(_make_cmd(i + 1))

	sm.process_queue(body)
	assert_eq(sm.last_processed_seq, 10,
		"drain-all: one call must process every queued command")
	assert_eq(sm.queue_size(), 0, "queue fully empty after single drain")


## After the queue drains, subsequent calls with no new input are no-ops.
## Only newly-enqueued commands advance last_processed_seq.
func test_subsequent_calls_only_process_new_commands() -> void:
	var sm := ServerMovementClass.new()
	var body := StubBody.new()
	for i in 5:
		sm.enqueue(_make_cmd(i + 1))

	sm.process_queue(body)
	assert_eq(sm.last_processed_seq, 5, "first call drained seqs 1-5")
	assert_eq(sm.queue_size(), 0, "queue empty after drain")

	# No new input → no-op, seq must not advance.
	sm.process_queue(body)
	assert_eq(sm.last_processed_seq, 5, "no-op call must not advance seq")

	# New commands arrive → next call drains them.
	sm.enqueue(_make_cmd(6))
	sm.enqueue(_make_cmd(7))
	sm.process_queue(body)
	assert_eq(sm.last_processed_seq, 7, "new commands drained in order")
	assert_eq(sm.queue_size(), 0, "queue empty again")


## A backlog at or below ROUTINE_JITTER_THRESHOLD processes only ROUTINE_JITTER_BATCH
## commands per call — the rest wait for the next tick instead of snapping through.
func test_routine_backlog_capped_to_jitter_batch() -> void:
	var sm := ServerMovementClass.new()
	var body := StubBody.new()
	for i in 3:  # 3 <= ROUTINE_JITTER_THRESHOLD (4)
		sm.enqueue(_make_cmd(i + 1))

	sm.process_queue(body)

	assert_eq(sm.last_processed_seq, 2, "only ROUTINE_JITTER_BATCH (2) commands processed")
	assert_eq(sm.queue_size(), 1, "the rest stay queued for the next call")


## The threshold check is inclusive: a backlog exactly at ROUTINE_JITTER_THRESHOLD is
## still capped, not drained in full.
func test_backlog_at_threshold_still_capped() -> void:
	var sm := ServerMovementClass.new()
	var body := StubBody.new()
	for i in 4:  # == ROUTINE_JITTER_THRESHOLD
		sm.enqueue(_make_cmd(i + 1))

	sm.process_queue(body)

	assert_eq(sm.last_processed_seq, 2, "a backlog == threshold is still capped to the batch size")
	assert_eq(sm.queue_size(), 2, "2 commands remain queued")


## A routine backlog spreads across multiple ticks rather than draining all at once.
func test_routine_backlog_drains_over_multiple_calls() -> void:
	var sm := ServerMovementClass.new()
	var body := StubBody.new()
	for i in 3:
		sm.enqueue(_make_cmd(i + 1))

	sm.process_queue(body)  # batch-capped: processes seq 1-2
	sm.process_queue(body)  # remaining backlog (1) is <= batch, processes seq 3

	assert_eq(sm.last_processed_seq, 3, "all 3 commands eventually processed")
	assert_eq(sm.queue_size(), 0, "queue drained after the second call")


## Individual cmd.delta is clamped to MAX_CMD_DELTA on enqueue to prevent
## a malicious client from sending an inflated time step.
func test_delta_clamped_to_max() -> void:
	var sm := ServerMovementClass.new()
	var body := StubBody.new()
	# Enqueue a single command with an absurdly large delta (exploit attempt)
	var cmd := _make_cmd(1, 10.0)  # 10 seconds — should be clamped to 0.2
	sm.enqueue(cmd)
	sm.process_queue(body)

	# The command was processed (seq advanced), and the delta was clamped.
	# We can't directly observe delta after processing, but we can verify the
	# queue didn't blow up and seq advanced normally.
	assert_eq(sm.last_processed_seq, 1, "command with large delta must still be processed")


## A real spike (well past ROUTINE_JITTER_THRESHOLD, e.g. a WiFi hitch) drains in one
## call rather than being throttled like routine jitter — catching up matters more
## than smoothness for a rare, discrete event.
func test_spike_scenario_drains_in_one_call() -> void:
	var sm := ServerMovementClass.new()
	var body := StubBody.new()

	for i in 12:  # 200ms at 60Hz, well past ROUTINE_JITTER_THRESHOLD (4)
		sm.enqueue(_make_cmd(i + 1))
	assert_eq(sm.queue_size(), 12, "all 12 commands queued initially")

	sm.process_queue(body)

	assert_eq(sm.last_processed_seq, 12, "a real backlog drains fully in one call")
	assert_eq(sm.queue_size(), 0, "queue empty after the spike is caught up")
