class_name ClientMovement extends RefCounted
## Client-side predicted movement — mirrors ServerMovement's API.
##
## Owns a MovementState and prediction buffer internally.
## Call predict() each physics frame, reconcile() when server state arrives.

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
# The prediction harness owns the generic loop (unacked history, out-of-order rejection,
# match-by-ack, replay, prune); this class supplies the movement-specific pieces. Preloaded by path
# so the bare `-s` test runner resolves it without a class-registry rescan.
const PredictionBufferClass = preload("res://addons/pmove/net/prediction_buffer.gd")


## Server-authoritative state received from the network.
class ServerState:
	var seq: int
	var position: Vector3
	var velocity: Vector3
	var is_crouched: bool
	var on_floor: bool
	var is_jumping: bool

	func _init(p_seq: int, p_pos: Vector3, p_vel: Vector3,
			p_crouched: bool, p_on_floor: bool, p_jumping: bool = false) -> void:
		seq = p_seq
		position = p_pos
		velocity = p_vel
		is_crouched = p_crouched
		on_floor = p_on_floor
		is_jumping = p_jumping


var cfg: MovementConfig
var state: Movement.MovementState
var _sim: Movement.Simulation
var _pb                  # prediction harness; stores { seq, cmd, snapshot, modifiers }
var _next_seq := 1       # see get_next_seq()


## `p_harness` overrides the bundled PredictionBuffer with anything exposing its four members
## (record / reconcile / unacked_count / clear) — for a game whose netcode already keeps an input
## history, or a test that wants to watch what gets recorded.
func _init(p_cfg: MovementConfig = null, p_harness = null) -> void:
	cfg = p_cfg if p_cfg != null else MovementConfig.new()
	_sim = Movement.Simulation.new(cfg)
	state = Movement.MovementState.new()
	_pb = p_harness if p_harness != null else PredictionBufferClass.new()


## Monotonic id for the next command. Owned here rather than by the harness because the rule it
## obeys is a movement one: it must keep climbing across clear(), or the server drops the first
## commands after a respawn as duplicates of the pre-death ones and the player cannot move.
func get_next_seq() -> int:
	var seq := _next_seq
	_next_seq += 1
	return seq


## Seq of the most recently generated command (get_next_seq() - 1), or 0 before the first one.
func last_seq() -> int:
	return _next_seq - 1


## Bind the sim state to the physics body it describes. Call as soon as the body exists —
## state.position is a view over the body transform, so binding early makes out-of-band
## moves (spawn placement, teleport) visible without waiting for the first predicted tick.
func bind_body(body) -> void:
	state.bind_body(body)


func predict(body, cmd, modifier_callback: Callable = Callable()) -> void:
	## modifier_callback signature: (cmd) -> Movement.MovementModifiers
	state.bind_body(body)
	state.velocity = body.velocity
	var modifiers := Movement.MovementModifiers.new()
	if modifier_callback.is_valid():
		modifiers = modifier_callback.call(cmd)
	modifiers.apply_to(state)
	_sim.simulate_tick(body, state, cmd)
	# snapshot = predicted state after this tick; context = modifiers (replayed data-driven).
	_pb.record(cmd.seq, cmd, state.snapshot(), modifiers)


## Detailed correction info from the last reconcile() call.
## Only valid when reconcile() returns true.
var last_correction: Dictionary = {}


func reconcile(body, server: ServerState) -> bool:
	## Returns true if a correction was applied.
	##
	## The generic control flow lives in PredictionBuffer; this method supplies the movement-specific
	## pieces: the divergence test, the snap-to-server, and re-simulating each replayed command.
	## Replay is data-driven from stored MovementModifiers, so live-state queries (expired frost,
	## exited ladder) can't diverge from the original prediction. GoldSrc-faithful: always reconcile
	## when positions differ beyond replay noise, so real physics divergence is never masked.

	# Divergence test: correct only past replay noise. Replay runs move_and_slide N times/frame vs
	# once/frame on the server, so ~0.5mm mismatches are jitter; correcting them triggers a replay that
	# amplifies the error. 5mm absorbs the noise yet still catches real divergence (real errors > 100mm).
	const CORRECTION_THRESHOLD_SQ := 0.005 * 0.005
	var result = _pb.reconcile(server.seq, func(pred: Dictionary) -> bool:
		return (pred["position"] as Vector3).distance_squared_to(server.position) >= CORRECTION_THRESHOLD_SQ)

	if result == null:
		return false

	var predicted: Dictionary = result["predicted"]
	var predicted_pos: Vector3 = predicted["position"]

	# Capture debug info before overwriting state
	var pred_vel: Vector3 = predicted["velocity"]
	var srv_vel: Vector3 = server.velocity
	var diff: Vector3 = predicted_pos - server.position
	last_correction = {
		"seq": server.seq,
		"predicted_pos": predicted_pos,
		"server_pos": server.position,
		"predicted_vel_y": pred_vel.y,
		"server_vel_y": srv_vel.y,
		"predicted_vxz": Vector2(pred_vel.x, pred_vel.z).length(),
		"server_vxz": Vector2(srv_vel.x, srv_vel.z).length(),
		"predicted_on_floor": predicted.get("on_floor", false),
		"server_on_floor": server.on_floor,
		"predicted_is_jumping": predicted.get("is_jumping", false),
		"server_is_jumping": server.is_jumping,
		"dist": predicted_pos.distance_to(server.position),
		"dist_y": diff.y,
		"dist_lateral": Vector2(diff.x, diff.z).length(),
		"unacked": result["replay"].size(),
		"replay_pos": Vector3.ZERO,  # filled after replay
	}

	# Snap to server state — restore() writes state.position, which is the body
	# transform itself, so the body lands on the server position with it.
	state.bind_body(body)
	state.restore({
		"position": server.position,
		"velocity": server.velocity,
		"is_crouched": server.is_crouched,
		"is_jumping": server.is_jumping,
		"on_floor": server.on_floor,
	})
	body.velocity = state.velocity
	# Force physics server to use the corrected position immediately so
	# move_and_slide during replay doesn't use stale broadphase data.
	if body.has_method("force_sync_physics"):
		body.force_sync_physics()

	# Replay unacked commands using stored modifiers — these were captured at
	# prediction time and are authoritative for replay. Using live state here
	# would diverge: frost may have expired, player may have left a ladder, etc.
	# Velocity impulses (e.g. levitate lift) are also stored in the modifiers,
	# so no live callback is needed.
	# Save the yaw — replay sets body.yaw from old commands, but the yaw is
	# client-authoritative and must not be overwritten.
	var saved_yaw: float = body.yaw
	for entry in result["replay"]:
		var mods: Movement.MovementModifiers = entry["context"]
		mods.apply_to(state)
		_sim.simulate_tick(body, state, entry["input"])
		# Keep the physics server broadphase current after each command so the
		# next simulate_tick queries collision from the correct position.
		# Without this, replay runs N move_and_slide calls in one physics frame
		# against a stale AABB — on ramps this causes premature floor detection
		# (client "lands" mid-jump while server is still ascending).
		if body.has_method("force_sync_physics"):
			body.force_sync_physics()
	body.yaw = saved_yaw

	last_correction["replay_pos"] = body.global_position
	return true


func clear() -> void:
	## Clear prediction buffer. Does NOT reset the seq counter — seq must be monotonically
	## increasing across death/respawn, otherwise the server drops post-respawn commands as
	## duplicates of pre-death ones. See get_next_seq(), which owns it for that reason.
	_pb.clear()


func buffer_size() -> int:
	return _pb.unacked_count()
