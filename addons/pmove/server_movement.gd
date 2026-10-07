class_name ServerMovement extends RefCounted

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")

## Hard count cap — protects against floods/cheaters sending huge command bursts.
const MAX_QUEUE_DEFAULT := 64
var max_queue := MAX_QUEUE_DEFAULT


## Clamp individual cmd.delta to prevent exploit-inflated time steps.
## Mirrors Quake 3's 200ms cap (and GoldSrc's practical limit).
const MAX_CMD_DELTA := 0.2

## Routine network jitter (a handful of commands arriving together even on a good
## connection) queues up 2-4 commands behind. Draining all of them in one physics tick
## moves this body several ticks' worth of distance in a single step, then leaves it
## motionless the next tick once the queue is empty — a fast-jump-then-freeze pattern
## that reads as "snapping" to anyone watching this body live (host puppets render
## straight off state.position with no interpolation/smoothing — see remote_player.gd
## is_host_puppet — so a burst here is visible raw on the host's own screen). Capping
## routine bursts to a couple of commands per tick spreads that motion back out.
## A backlog past ROUTINE_JITTER_THRESHOLD is treated as real loss/hitch recovery
## rather than routine jitter, and still drains in one tick as before — catching up
## fast after an actual gap matters more than smoothness there, and it's a rare,
## discrete event rather than a steady-state annoyance.
const ROUTINE_JITTER_BATCH := 2
const ROUTINE_JITTER_THRESHOLD := 4

var cfg: MovementConfig
var state: Movement.MovementState
var last_processed_seq: int = -1
var last_yaw: float = 0.0
var last_pitch: float = 0.0
var noclip_grant: bool = false
var _sim: Movement.Simulation
var _input_queue: Array = []
var _highest_enqueued_seq: int = 0


func _init(p_cfg: MovementConfig = null) -> void:
	cfg = p_cfg if p_cfg != null else MovementConfig.new()
	_sim = Movement.Simulation.new(cfg)
	state = Movement.MovementState.new()


func bind_body(body) -> void:
	## Bind the sim state to the physics body it describes. Call this as soon as the
	## body exists (not just at the first processed tick) so out-of-band moves before
	## any input arrives — spawn placement, a teleport while dead — are already visible
	## through state.position.
	state.bind_body(body)


func enqueue(cmd) -> void:
	if cmd.seq <= last_processed_seq:
		return
	# Skip duplicates already in the queue (from redundant sends)
	for existing in _input_queue:
		if existing.seq == cmd.seq:
			return
	_highest_enqueued_seq = maxi(_highest_enqueued_seq, cmd.seq)
	_input_queue.append(cmd)
	if _input_queue.size() > max_queue:
		_input_queue.pop_front()


func process_queue(body, modifier_callback: Callable = Callable(),
		on_landing: Callable = Callable()) -> void:
	## GoldSrc-faithful, with one deliberate deviation: process queued commands per
	## tick, capped at ROUTINE_JITTER_BATCH while the backlog is still small.
	##
	## GoldSrc processes every pending command each server frame and never drops or
	## defers. This is safe because BSP queries are stateless. In Godot, multiple
	## move_and_slide calls per frame use stale broadphase data, so we call
	## force_sync_physics() between commands (same approach as client reconcile
	## replay). This keeps each simulate_tick starting from a fresh physics state,
	## matching the client's 1-per-frame prediction.
	##
	## Processing all queued commands per tick means the server self-corrects clock
	## drift naturally: if the server falls behind (e.g. from WiFi bursts or a slow
	## frame), it catches up. Since physics is deterministic, the replayed positions
	## match the client's predictions exactly — no corrections fire, whether that
	## catch-up happens in one tick or is spread over a couple. What changes with the
	## cap is only WHEN last_processed_seq reaches a given command, not WHAT position
	## it computes — so this doesn't reopen the "server ahead of what client
	## predicted" case the uncapped drain was built to avoid.
	##
	## A backlog past ROUTINE_JITTER_THRESHOLD skips the cap and drains in one tick,
	## same as before — real loss/hitch recovery should still catch up immediately.
	##
	## MAX_QUEUE in enqueue() still caps queue size against floods/cheaters.

	# Sync velocity from the body — it is the single source of truth between ticks,
	# matching how client predict() works, so an external write (knockback,
	# trigger_push, etc.) is picked up without also touching state directly.
	# Position needs no sync: state.position IS the body transform once bound.
	state.bind_body(body)
	state.velocity = body.velocity

	_input_queue.sort_custom(func(a, b) -> bool:
		return a.seq < b.seq)

	while not _input_queue.is_empty() and _input_queue[0].seq <= last_processed_seq:
		_input_queue.pop_front()

	if _input_queue.is_empty():
		return

	# Clamp delta and apply server-authoritative noclip grant (anti-cheat).
	for cmd in _input_queue:
		cmd.delta = minf(cmd.delta, MAX_CMD_DELTA)
		cmd.noclip = noclip_grant

	# Process queued commands, syncing broadphase between each so move_and_slide never
	# operates on stale AABB data. Routine-sized backlogs are capped per tick (see
	# ROUTINE_JITTER_BATCH above); a real backlog still drains in full.
	# modifier_callback signature: (cmd) -> Movement.MovementModifiers
	var to_process := _input_queue.size()
	if to_process <= ROUTINE_JITTER_THRESHOLD:
		to_process = mini(to_process, ROUTINE_JITTER_BATCH)
	var processed := 0
	while not _input_queue.is_empty() and processed < to_process:
		var cmd = _input_queue.pop_front()
		if modifier_callback.is_valid():
			var mods: Movement.MovementModifiers = modifier_callback.call(cmd)
			mods.apply_to(state)
		_sim.simulate_tick(body, state, cmd)
		# Fall damage: fire per landing tick (not once after the batch) so a landing
		# on an early command in a high-latency batch isn't clobbered by later ones.
		if state.landing_impact_speed > 0.0 and on_landing.is_valid():
			on_landing.call(state.landing_impact_speed)
		last_processed_seq = cmd.seq
		last_yaw = cmd.yaw
		last_pitch = cmd.pitch
		processed += 1
		if processed < to_process and not _input_queue.is_empty() \
				and body.has_method("force_sync_physics"):
			body.force_sync_physics()


func queue_size() -> int:
	return _input_queue.size()


func clear_queue() -> void:
	## Clear queued commands without resetting last_processed_seq.
	## Use this on respawn/teleport to discard stale commands while still
	## rejecting already-processed sequence numbers.
	_input_queue.clear()


func clear() -> void:
	## Full reset — clears queue and allows all sequence numbers.
	## Use only when the client will also reset its sequence counter
	## (e.g. on initial join/team change).
	_input_queue.clear()
	last_processed_seq = -1
