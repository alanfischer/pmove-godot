extends RefCounted
## The generic half of client-side prediction: a history of still-unacked inputs, and the
## bookkeeping that decides what to replay when the server acks one.
##
## Deliberately knows nothing about movement. It owns only the control flow — keep each
## locally-simulated input with the state it predicted, and when the server acks an input,
## reject out-of-order acks, find the matching input, decide whether the prediction diverged,
## and report the still-unacked inputs to replay on top of the authoritative state. The
## domain-specific pieces stay with the caller:
##   - what a "snapshot" of predicted state is (captured at record() time; opaque here),
##   - how far off counts as diverged (a predicate passed to reconcile()),
##   - how to apply the server state and how to re-simulate one input.
## ClientMovement is the caller that drives it for GoldSrc movement; the same buffer would
## serve a vehicle or anything else with an input -> state simulation.
##
## This class IS the duck-typed harness interface ClientMovement expects — four members:
##
##   record(seq, input, snapshot, context) -> void
##   reconcile(acked_seq, diverged: Callable) -> Variant   # null, or { predicted, replay }
##   unacked_count() -> int                                # diagnostics only
##   clear() -> void
##
## Anything exposing those works, so a game whose netcode already keeps an input history can
## adapt it rather than run a second buffer over the same inputs. Note that the sequence
## counter is NOT part of this: the caller owns it, because the rule that it must keep climbing
## across clear() is the caller's requirement to state (see ClientMovement.clear()).
##
## Determinism note: replay is data-driven from the `context` captured at record() time, never
## from live state — so state that has since changed (an expired buff, a lane since left) cannot
## make the replay diverge from what was originally predicted.

## Max unacked inputs retained (~2.1 s at 60 Hz). Oldest drop if the server never acks.
var max_buffer := 128

var _buffer: Array = []            # [{ seq, input, snapshot, context }], oldest first
var _highest_reconciled_seq := -1  # reject out-of-order / already-superseded server acks
var _replay_end_seq := -1          # inputs <= this were produced by a replay; don't re-correct them


## Record a locally-simulated input as unacked. `snapshot` is your opaque capture of the predicted
## state right after simulating this input (reconcile hands it back to the `diverged` predicate);
## `context` is opaque data replayed with the input on correction (e.g. modifiers captured now).
func record(seq: int, input: Variant, snapshot: Variant, context: Variant = null) -> void:
	_buffer.append({ "seq": seq, "input": input, "snapshot": snapshot, "context": context })
	if _buffer.size() > max_buffer:
		_buffer.pop_front()


## Process the server's ack for `acked_seq` (whose authoritative state your `diverged` predicate
## closes over).
##
## Returns null when no correction is needed — the common per-tick answer, and the reason this
## returns null rather than a { corrected: false } record: the hot path then allocates nothing and
## the caller needs one truthiness check instead of reading one key to decide whether another is
## present. On a correction it returns:
##   { predicted, replay }
## where `replay` is the still-unacked inputs (each { input, context }, in order) to re-simulate
## after you snap the body to the server state, and `predicted` is the opaque snapshot recorded for
## the acked input (for the caller's diagnostics; `replay.size()` is the number of inputs replayed).
##
## The acked input and everything older are pruned in every accepted path, so the buffer then holds
## only still-unacked inputs.
##
## `diverged.call(predicted_snapshot) -> bool` decides whether the prediction for the acked input is
## far enough from the server's state to warrant a correction. It is called at most once per
## reconcile, and only when the acked input hasn't already been superseded or replayed.
func reconcile(acked_seq: int, diverged: Callable) -> Variant:
	# Out-of-order / superseded: we already reconciled this seq or a newer one.
	if acked_seq <= _highest_reconciled_seq:
		return null
	var match_idx := -1
	for i in _buffer.size():
		if _buffer[i]["seq"] == acked_seq:
			match_idx = i
			break
	if match_idx == -1:
		return null
	_highest_reconciled_seq = acked_seq
	# Suppress corrections for inputs a prior correction already replayed: replayed snapshots are
	# non-deterministic (the caller re-runs many sim steps in one frame vs one/frame on the server),
	# so re-comparing them chains corrections. Trust the server state and let fresh predictions settle.
	if acked_seq <= _replay_end_seq:
		_prune_up_to(match_idx)
		return null
	var predicted: Variant = _buffer[match_idx]["snapshot"]
	if not diverged.call(predicted):
		_prune_up_to(match_idx)
		return null
	var replay: Array = []
	for i in range(match_idx + 1, _buffer.size()):
		replay.append({ "input": _buffer[i]["input"], "context": _buffer[i]["context"] })
	# The last unacked input is now the newest replayed seq — inputs up to it are non-deterministic.
	if _buffer.size() > 0:
		_replay_end_seq = _buffer[_buffer.size() - 1]["seq"]
	_prune_up_to(match_idx)
	return { "predicted": predicted, "replay": replay }


## Number of still-unacked recorded inputs. Diagnostics only — nothing in the prediction loop
## reads it, so an adapted harness that cannot answer cheaply may return 0.
func unacked_count() -> int:
	return _buffer.size()


## Drop unacked history + reconciliation guards. The caller's sequence counter is untouched
## because this buffer does not own it.
func clear() -> void:
	_buffer.clear()
	_highest_reconciled_seq = -1
	_replay_end_seq = -1


## Discard the matched entry and everything older, keeping only still-unacked inputs. In-place
## shift to avoid reallocating a new array.
func _prune_up_to(idx: int) -> void:
	var start := idx + 1
	if start < _buffer.size():
		var remaining := _buffer.size() - start
		for i in remaining:
			_buffer[i] = _buffer[i + start]
		_buffer.resize(remaining)
	else:
		_buffer.clear()
