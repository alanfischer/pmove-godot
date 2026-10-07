extends "res://tests/suite.gd"
## PredictionBuffer — the client-side prediction / reconciliation harness.
##
## Simulation-agnostic and fully deterministic: it owns the unacked input history and the
## decision of what to replay. All of that is testable in-process with a stub `diverged`
## predicate standing in for the caller's state comparison.
##
## The subtle behavior — and the reason this is worth testing rather than eyeballing — is
## the replay suppression via `_replay_end_seq`. Replayed snapshots are non-deterministic
## (the client re-runs many sim steps in one frame where the server ran one per tick), so
## re-comparing them chains corrections into a feedback loop: a correction causes a replay,
## the replayed states don't match, that triggers another correction, and the body rubber-
## bands indefinitely. Nothing about that is visible in a single-step reading of the code.
##
## Sequence ids are passed in explicitly here because the buffer does not own the counter —
## ClientMovement does (see its get_next_seq), so the seqs a test records under are its own
## business and spelling them out makes each case's ack arithmetic readable.

const PB := preload("res://addons/pmove/prediction_buffer.gd")

## `diverged` predicates. reconcile() takes a Callable so the caller can close over the
## server state; the tests only need the two constant answers plus a spy.
static func _always(_predicted: Variant) -> bool:
	return true

static func _never(_predicted: Variant) -> bool:
	return false


func test_record_and_count() -> void:
	var pb := PB.new()
	assert_eq(pb.unacked_count(), 0, "nothing unacked initially")
	for i in 3:
		pb.record(i + 1, "input%d" % i, "snap%d" % i)
	assert_eq(pb.unacked_count(), 3, "every recorded input is unacked until the server acks it")


# --- acks that must not correct ---

func test_unknown_ack_ignored() -> void:
	# An ack for an input we never recorded (or already pruned) tells us nothing.
	var pb := PB.new()
	pb.record(1, "i1", "s1")
	assert_eq(pb.reconcile(999, _always), null, "an ack for an unknown seq does not correct")
	assert_eq(pb.unacked_count(), 1, "an unknown ack prunes nothing")


func test_out_of_order_ack_ignored() -> void:
	# Acks arrive over an unreliable channel. Once seq 3 is reconciled, a late ack for
	# seq 2 is stale — acting on it would rewind to superseded state.
	#
	# SCOPE — established by mutation: deleting the `_highest_reconciled_seq` guard leaves
	# this test passing. Not a gap in the test so much as a fact about the code: every
	# accepted reconcile prunes the acked input and everything older, so by the time a stale
	# ack arrives its seq is no longer in the buffer and the `match_idx == -1` path returns
	# the same no-correction result. The guard is belt-and-braces for a caller that records
	# a seq out of order (record() takes the seq as a parameter), which is why it can't be
	# provoked through normal use. The assertions below still pin the observable contract.
	var pb := PB.new()
	for i in 4:
		pb.record(i + 1, "i%d" % i, "s%d" % i)
	assert_ne(pb.reconcile(3, _always), null, "the first ack reconciles normally")

	assert_eq(pb.reconcile(2, _always), null, "an ack older than the last reconciled seq is ignored")
	assert_eq(pb.reconcile(3, _always), null, "re-acking the same seq is ignored")


func test_converged_ack_prunes_without_correcting() -> void:
	# The common case: the prediction was right. No correction, but the acked input and
	# everything older must still be dropped or the buffer grows without bound.
	var pb := PB.new()
	for i in 5:
		pb.record(i + 1, "i%d" % i, "s%d" % i)
	assert_eq(pb.reconcile(3, _never), null, "a converged prediction does not correct")
	assert_eq(pb.unacked_count(), 2, "the acked input and everything older are pruned anyway")


# --- divergence ---

func test_divergence_returns_replay_in_order() -> void:
	var pb := PB.new()
	for i in 5:
		pb.record(i + 1, "i%d" % i, "s%d" % i)  # seqs 1..5

	var r = pb.reconcile(2, _always)
	assert_ne(r, null, "a diverged prediction corrects")

	# Replay is the STILL-UNACKED inputs — everything after the acked one, in order. The
	# acked input itself is not replayed: the server's state already includes it.
	var replay: Array = r["replay"]
	assert_eq(replay.size(), 3, "replay holds the inputs after the acked one")
	for i in replay.size():
		assert_eq(replay[i]["input"], "i%d" % (i + 2), "replay entry %d is in submission order" % i)
	assert_eq(pb.unacked_count(), 3, "the acked input and older are pruned, unacked ones kept")


func test_replay_carries_context() -> void:
	# Replay is data-driven from the context captured at record() time, never from live
	# state — so a modifier that has since expired can't change what the replay produces.
	var pb := PB.new()
	pb.record(1, "i1", "s1", {"speed": 1.0})
	pb.record(2, "i2", "s2", {"speed": 2.0})
	pb.record(3, "i3", "s3", {"speed": 3.0})

	var r = pb.reconcile(1, _always)
	assert_ne(r, null, "a diverged prediction corrects")
	var replay: Array = r["replay"]
	assert_eq(replay.size(), 2, "two inputs to replay")
	assert_eq(replay[0]["context"]["speed"], 2.0, "replay carries the context recorded with input 2")
	assert_eq(replay[1]["context"]["speed"], 3.0, "replay carries the context recorded with input 3")


func test_predicate_receives_the_recorded_snapshot() -> void:
	# The predicate must be handed the snapshot recorded for the ACKED input specifically —
	# handing it the newest (or oldest) one would compare the server's state against a
	# prediction from a different tick, which is how a correct prediction reads as diverged.
	var pb := PB.new()
	for i in 4:
		pb.record(i + 1, "i%d" % i, "snapshot-for-seq-%d" % (i + 1))

	var seen: Array = []
	var spy := func(predicted: Variant) -> bool:
		seen.append(predicted)
		return true

	var r = pb.reconcile(2, spy)
	assert_eq(seen.size(), 1, "the predicate is called exactly once per reconcile")
	assert_eq(seen[0], "snapshot-for-seq-2", "the predicate sees the acked input's snapshot")
	assert_eq(r["predicted"], "snapshot-for-seq-2", "the result reports the same snapshot")


func test_replayed_inputs_are_not_recorrected() -> void:
	# The rubber-banding guard. After a correction replays seqs 3..5, the server's acks for
	# those seqs will arrive later. Comparing against their (non-deterministically replayed)
	# snapshots would trigger another correction, which replays again, forever. They must be
	# pruned quietly instead — and normal correction must resume for inputs recorded after.
	var pb := PB.new()
	for i in 5:
		pb.record(i + 1, "i%d" % i, "s%d" % i)  # seqs 1..5

	var first = pb.reconcile(2, _always)
	assert_ne(first, null, "the initial divergence corrects")
	assert_eq((first["replay"] as Array).size(), 3, "seqs 3..5 were replayed")

	var calls := 0
	var counting := func(_predicted: Variant) -> bool:
		calls += 1
		return true

	# Acks for the replayed seqs: suppressed, and the predicate isn't even consulted.
	for seq in [3, 4, 5]:
		assert_eq(pb.reconcile(seq, counting), null,
			"ack for replayed seq %d does not re-correct" % seq)
	assert_eq(calls, 0, "the divergence predicate is not consulted for replayed inputs")
	assert_eq(pb.unacked_count(), 0, "replayed inputs are still pruned as they are acked")

	# Fresh inputs recorded after the replay window are predicted normally again — the
	# suppression must be a window, not a permanent off switch.
	pb.record(6, "i6", "s6")
	pb.record(7, "i7", "s7")
	assert_ne(pb.reconcile(6, _always), null,
		"corrections resume for inputs recorded after the replay")


# --- housekeeping ---

func test_max_buffer_eviction() -> void:
	# If the server stops acking, the buffer must not grow forever.
	var pb := PB.new()
	pb.max_buffer = 4
	for i in 20:
		pb.record(i + 1, "i%d" % i, "s%d" % i)
	assert_eq(pb.unacked_count(), 4, "the unacked buffer is capped at max_buffer")
	# The oldest were dropped, so only the newest 4 seqs (17..20) are still ackable.
	assert_eq(pb.reconcile(1, _always), null, "an evicted seq is no longer ackable")
	assert_ne(pb.reconcile(18, _always), null, "a retained seq still reconciles")


func test_clear_drops_history() -> void:
	# The caller's sequence counter is NOT this buffer's business (ClientMovement keeps
	# climbing across a respawn); clear() drops the unacked history and the guards.
	var pb := PB.new()
	for i in 3:
		pb.record(i + 1, "i%d" % i, "s%d" % i)
	pb.clear()
	assert_eq(pb.unacked_count(), 0, "clear() drops unacked history")

	# The reconciliation guards must have been cleared too, or the first ack after a
	# respawn would be rejected as superseded by the pre-clear session.
	pb.record(4, "i4", "s4")
	assert_ne(pb.reconcile(4, _always), null, "reconcile corrects again after clear()")


func test_no_correction_returns_null() -> void:
	# The no-correction path is the per-tick common case, so it returns null rather than a
	# { corrected: false } record: nothing is allocated, and there is no shared const
	# Dictionary for a caller to mutate and corrupt every later return.
	var pb := PB.new()
	pb.record(1, "i1", "s1")
	assert_eq(pb.reconcile(99, _never), null, "an unknown ack returns null")
	assert_eq(pb.reconcile(98, _never), null, "and keeps returning null")
