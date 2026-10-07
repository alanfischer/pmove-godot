const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")

## Floor normal.y above which a surface is standable (~45°, matches GoldSrc and the
## player body's default floor_max_angle).
const WALK_NORMAL_Y := 0.7


# --- MovementState: sim data; position is a view over the bound body ---

class MovementState:
	## The body this state is a view over — bound by simulate_tick (and eagerly by
	## ServerMovement/ClientMovement.bind_body) so it is set before the first tick.
	## Duck-typed: anything exposing a `global_position` property works.
	var _body = null
	## Storage used only while unbound (a bare MovementState in a unit test).
	var _position: Vector3 = Vector3.ZERO

	## Player position. Once bound this is the body transform itself — reads/writes go
	## straight through, so the sim position and the physics body can't drift apart, and
	## out-of-band moves (teleport, spawn placement) are seen immediately downstream.
	var position: Vector3:
		get: return _body.global_position if _body != null else _position
		set(v):
			if _body != null:
				_body.global_position = v
			else:
				_position = v

	var velocity: Vector3 = Vector3.ZERO

	## Crouch state, and the single owner of the collision hull's height. The hull is a
	## pure function of this flag, applied on write rather than by each caller, so
	## update_crouch and restore() both get a matching hull for free.
	var is_crouched: bool:
		get: return _is_crouched
		set(v):
			_is_crouched = v
			if _body != null:
				var h: float = _crouch_height if v else _stand_height
				_body.set_collision_height(h, h * 0.5)
	var _is_crouched: bool = false

	var is_jumping: bool = false
	var on_floor: bool = false
	var gravity_scale: float = 1.0
	var eye_y: float = 1.6  # default = stand_eye; kept in sync by simulate_tick

	# Cached from cfg so restore() can snap the eye and the hull without needing cfg
	# passed in (simulate_tick refreshes them every tick).
	var _stand_eye: float = 1.6
	var _crouch_eye: float = 0.75
	var _stand_height: float = 1.8
	var _crouch_height: float = 0.9

	# Generic modifiers — game sets these before simulate_tick via MovementModifiers.apply_to()
	var friction_scale: float = 1.0
	var accel_scale: float = 1.0
	var speed_scale: float = 1.0
	var is_move_locked: bool = false
	# GoldSrc basevelocity: extra velocity added to movement but NOT to player state.
	# Applied before move_and_slide, subtracted back out after — the player's own
	# velocity is preserved across the tick, matching GoldSrc PM basevelocity semantics.
	var base_velocity: Vector3 = Vector3.ZERO
	# Skip ground friction this tick (e.g. icy surface, separate from basevelocity).
	var no_friction: bool = false
	# GoldSrc pusher carry: world-space displacement of the mover underfoot this tick
	# (lift, golem). Applied as its own collision-checked move at the start of
	# simulate_tick, then cleared — transient, not part of snapshot()/restore(); replay
	# reapplies it from the stored per-tick MovementModifiers.
	var carry_motion: Vector3 = Vector3.ZERO
	# Unstick backstop: capped push out of a solid the hull ended up embedded in.
	# Transient like carry_motion, applied right after it, replayed the same way.
	var depenetration: Vector3 = Vector3.ZERO
	# The teleport kind of unstick — see where simulate_tick applies it. Same lifetime as the
	# two above: set before a tick, consumed by it, carried in the per-tick modifiers so replay
	# reproduces the displacement instead of re-deciding it.
	var unstick_offset: Vector3 = Vector3.ZERO
	# Override mode: game provides the full velocity instead of running normal movement.
	# Use for any non-standard physics (ladder, swimming, grapple, conveyor, etc.).
	var velocity_override_active: bool = false
	var override_velocity: Vector3 = Vector3.ZERO

	# Output: downward speed (m/s, positive) at the instant the player touched the
	# ground this tick, or 0.0 if they did not land. The server reads it after each
	# simulate_tick to apply fall damage; transient, never enters reconcile.
	var landing_impact_speed: float = 0.0

	# Output: world-space displacement the roomscale head_delta actually produced this
	# tick after collision. The VR layer compares this against the requested head_delta
	# to push the XR rig back by the unconsumed remainder. Transient, never reconciled.
	var head_consumed: Vector3 = Vector3.ZERO

	func bind_body(body) -> void:
		## Make this state a view over `body`. Idempotent; the body's transform wins,
		## so binding never yanks an already-placed body to the unbound fallback position.
		if body == null or body == _body:
			return
		_body = body

	func snapshot() -> Dictionary:
		return {
			"position": position,
			"velocity": velocity,
			"is_crouched": is_crouched,
			"is_jumping": is_jumping,
			"on_floor": on_floor,
		}

	func restore(snap: Dictionary) -> void:
		position = snap["position"]
		velocity = snap["velocity"]
		is_crouched = snap["is_crouched"]
		is_jumping = snap["is_jumping"]
		on_floor = snap["on_floor"]
		# eye_y is derived from is_crouched — not stored in snapshots.
		# Snapping to target on restore ensures the eye origin is always correct
		# regardless of when the restore happens (e.g. after a network correction).
		eye_y = _crouch_eye if is_crouched else _stand_eye
		# The hull needs no line here: assigning is_crouched above resized it.


class MovementModifiers:
	## Game-set values applied to MovementState once per tick, before simulate_tick.
	## Return one of these from the modifier callback passed to predict() / process_queue().
	## Stored per-tick in the prediction buffer so reconcile replay is fully data-driven —
	## no live callback needed, so a live-state query (expired frost, exited ladder)
	## can't diverge from the original prediction.
	var gravity_scale: float = 1.0
	var speed_scale: float = 1.0
	var friction_scale: float = 1.0
	var accel_scale: float = 1.0
	var is_move_locked: bool = false
	## Override mode: skip normal movement and use override_velocity directly.
	## The game layer computes the full velocity (ladder, swimming, grapple, etc.)
	## and sets these.
	var velocity_override_active: bool = false
	var override_velocity: Vector3 = Vector3.ZERO
	## Per-axis velocity impulse applied before simulate_tick.
	## Non-zero components SET state.velocity (not added) — e.g. levitate sets y,
	## a knockback could set x/z. Zero components are left untouched.
	var velocity_impulse: Vector3 = Vector3.ZERO
	## GoldSrc basevelocity: push force for this tick (applied to movement, not player state).
	var base_velocity: Vector3 = Vector3.ZERO
	## Skip ground friction this tick (e.g. icy surface, separate from basevelocity).
	var no_friction: bool = false
	## GoldSrc pusher carry: displacement of the mover underfoot this tick.
	var carry_motion: Vector3 = Vector3.ZERO
	## Unstick backstop: last-resort push out of a solid the hull is embedded in
	## (a mover the pusher couldn't keep ahead of, two parts pinching). Applied
	## collision-checked alongside carry, capped per tick by the game layer.
	var depenetration: Vector3 = Vector3.ZERO
	## Teleport out of a pose no sweep can leave (Movement.find_unstick_offset).
	var unstick_offset: Vector3 = Vector3.ZERO

	func apply_to(state: MovementState) -> void:
		state.gravity_scale = gravity_scale
		state.speed_scale = speed_scale
		state.friction_scale = friction_scale
		state.accel_scale = accel_scale
		state.is_move_locked = is_move_locked
		state.velocity_override_active = velocity_override_active
		state.override_velocity = override_velocity
		state.base_velocity = base_velocity
		state.no_friction = no_friction
		state.carry_motion = carry_motion
		state.depenetration = depenetration
		state.unstick_offset = unstick_offset
		if velocity_impulse.x != 0.0: state.velocity.x = velocity_impulse.x
		if velocity_impulse.y != 0.0: state.velocity.y = velocity_impulse.y
		if velocity_impulse.z != 0.0: state.velocity.z = velocity_impulse.z


# --- Pure static helpers (no cfg needed) ---

## One wire quantum along each axis, then the eight corners of that cube, then the big moves —
## the search order GoldSrc's PM_CheckStuck uses, in GoldSrc units, expressed as the rule that
## generates it rather than as a transcribed table.
##
## The ordering is the whole point. The engine commits only past its 27th candidate on the slow
## path; here the caller decides what to do with the answer, so smallest-first is what carries the
## intent: the least displacement that frees the hull wins, and a stuck body gets nudged rather
## than teleported.
##
## The quantum is 1/8 unit, GoldSrc's wire coordinate precision, which is what the original search
## was sized for ("to allow for the cut precision of the net coordinates"). It is kept because it
## is also, by a coincidence worth knowing, four times DIST_EPSILON — comfortably outside the band
## a hull trace cannot answer from, which is what this search gets used for here.
const STUCK_QUANTUM := 0.125
## Built once on first access. Treat as read-only: it is shared by every caller.
static var STUCK_OFFSETS: Array[Vector3] = _build_stuck_offsets()


static func _build_stuck_offsets() -> Array[Vector3]:
	var out: Array[Vector3] = []
	var q := STUCK_QUANTUM
	# One quantum along each axis, vertical first: a hull resting in a brush seam is most often
	# freed by a lift, so it is the candidate worth spending the first query on.
	for axis in [Vector3.UP, Vector3.RIGHT, Vector3.BACK]:
		out.append(axis * q)
		out.append(-axis * q)
	# Then the eight corners of that same cube, for a seam no single axis clears.
	for sx in [1.0, -1.0]:
		for sy in [1.0, -1.0]:
			for sz in [1.0, -1.0]:
				out.append(Vector3(sx, sy, sz) * q)
	# Only once every cheap nudge has been refused: a step up, a hull-height lift, and two units
	# laterally — displacements large enough to be visible, which is why they come last.
	out.append(Vector3.UP * 1.0)
	out.append(Vector3.UP * 6.0)
	for axis in [Vector3.RIGHT, Vector3.BACK]:
		out.append(axis * 2.0)
		out.append(-axis * 2.0)
	return out
## How far a pose has to be able to travel to count as free. Smaller than any offset above, so
## "it moved" is never satisfied by the nudge itself.
const UNSTICK_PROBE := 0.02
## The directions is_pinned asks about. DOWN last on purpose: a pose anywhere near a floor refuses
## it, and every candidate offset in the table above is near one, so asking first spends a
## guaranteed-wasted query per candidate.
const PROBE_AXES: Array[Vector3] = [
	Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK, Vector3.UP, Vector3.DOWN,
]


## Whether the hull can move at all from `from_offset` (default: where it is now), in any axis.
##
## One refused direction is a wall and every mover meets those constantly. Six is a hull trace
## declining to answer, which is a different thing: it happens to a body left inside the
## DIST_EPSILON band a GoldSrc trace keeps its endpoints off surfaces by, and from there the
## body cannot walk, cannot fall, and is handed a contact that reads as solid ground. Nothing a
## mover steers can get it out, because nothing it asks for is granted.
static func is_pinned(body, from_offset := Vector3.ZERO) -> bool:
	for axis in PROBE_AXES:
		if body.can_move(axis * UNSTICK_PROBE, from_offset):
			return false
	return true


## The smallest offset from STUCK_OFFSETS that leaves `body` somewhere it can move again, or
## ZERO if none does. `unit` is metres per GoldSrc unit, passed in rather than read from the
## game so this file keeps its no-autoload property — which is what lets the pmove suites run
## without booting the scene.
##
## GoldSrc's own version asks PM_TestPlayerPosition instead ("am I inside something"), and that
## test passes in the pose this exists for: the point is in an empty leaf, with air under it, and
## only a trace FROM it is refused. So the question had to change even though the table did not.
##
## Returns an offset for the caller to apply — never moves the body itself. Both callers need it
## applied differently: a player's has to ride the per-tick modifiers so client replay reproduces
## it, a monster's does not.
static func find_unstick_offset(body, unit: float) -> Vector3:
	for offset in STUCK_OFFSETS:
		var candidate := offset * unit
		if not is_pinned(body, candidate):
			return candidate
	return Vector3.ZERO


class UnstickWatch:
	## When to ask the two questions above, and the whole of what both movers share about it.
	##
	## Six sweeps is not something to spend on a body that is plainly getting somewhere, and a
	## body merely leaning on a wall is steering's problem rather than this one's — so nothing is
	## asked until a mover has WANTED to move and failed to for STALL_TIME. Each caller then
	## applies the offset the way its own architecture demands, which is the one part that cannot
	## be shared: a player's has to ride the per-tick modifiers so client replay reproduces it, a
	## monster's is host-only and writes state directly.
	const STALL_DIST := 0.02   # got less than this far from where it was last checked...
	const STALL_TIME := 0.3    # ...for this long
	## After a search that found nothing, how long before trying again. The geometry has not
	## changed, so re-running 20 candidates every STALL_TIME is pure waste — a buried body would
	## spend ~420 queries a second proving the same thing. Moving at all clears it early.
	const RETRY_TIME := 3.0

	var _from := Vector3.INF
	var _t := 0.0
	var _retry := 0.0
	var _gave_up := false

	## The offset to apply, or ZERO for "nothing to do" — which is the answer on all but a
	## handful of ticks in a body's life. `wants_move` is the mover's own intent: a monster
	## standing still to throw, or a player not touching the keys, has no symptom to rescue.
	func poll(body, here: Vector3, delta: float, unit: float, wants_move: bool) -> Vector3:
		_gave_up = false
		_retry = maxf(_retry - delta, 0.0)
		if not wants_move or _from == Vector3.INF or here.distance_to(_from) > STALL_DIST:
			_from = here
			_t = 0.0
			_retry = 0.0   # it moved, so a previous failure says nothing about this pose
			return Vector3.ZERO
		_t += delta
		if _t < STALL_TIME or _retry > 0.0:
			return Vector3.ZERO
		_t = 0.0
		_from = here
		if not Movement.is_pinned(body):
			return Vector3.ZERO
		var offset := Movement.find_unstick_offset(body, unit)
		if offset == Vector3.ZERO:
			_retry = RETRY_TIME
			_gave_up = true
		return offset

	## True only for the poll whose search found a pinned pose it could not free — the caller's cue
	## to log it once rather than on every tick of the cooldown that follows.
	func gave_up() -> bool:
		return _gave_up

	func reset() -> void:
		_from = Vector3.INF
		_t = 0.0
		_retry = 0.0
		_gave_up = false


static func calc_wish_dir(cmd) -> Vector3:
	## Resolve input + yaw into world-space wish direction.
	var mi: Vector2 = cmd.move_input
	if mi == Vector2.ZERO:
		return Vector3.ZERO
	var basis := Basis(Vector3.UP, cmd.yaw)
	return (basis * Vector3(mi.x, 0.0, mi.y)).normalized()


## The command's full look orientation. Walking uses yaw only (calc_wish_dir above) because
## ground movement ignores pitch; the moves that fly — noclip, swimming, a ladder — aim where
## the player is actually looking, and need this.
static func camera_basis(cmd) -> Basis:
	return Basis(Vector3.UP, cmd.yaw) * Basis(Vector3.RIGHT, cmd.pitch)


# --- Simulation: owns a MovementConfig, runs all physics ---
# ServerMovement and ClientMovement each hold one of these.
# cmd parameter is untyped (Variant) to avoid class_name dependency issues
# in headless mode. It expects an InputCommand-shaped object with fields:
# move_input: Vector2, yaw: float, pitch: float, delta: float,
# jump: bool, jump_just_pressed: bool, crouch: bool, walk: bool, noclip: bool

class Simulation:
	var cfg: MovementConfig

	func _init(p_cfg: MovementConfig) -> void:
		cfg = p_cfg


	func get_max_speed(state: MovementState, cmd) -> float:
		var speed: float = cfg.max_speed * state.speed_scale
		if state.is_crouched:
			speed *= cfg.duck_mult
		if cmd.walk:
			speed *= cfg.walk_mult
		return speed


	func apply_friction(state: MovementState, delta: float) -> void:
		## Quake/HL ground friction: PM_Friction
		if state.no_friction:
			return
		var speed := state.velocity.length()
		if speed < 0.1:
			state.velocity.x = 0.0
			state.velocity.z = 0.0
			return
		var control := maxf(speed, cfg.stop_speed)
		var drop := control * cfg.friction * state.friction_scale * delta
		var new_speed := maxf(speed - drop, 0.0)
		state.velocity *= (new_speed / speed)


	func ground_accelerate(state: MovementState, wish_dir: Vector3,
			wish_speed: float, delta: float) -> void:
		## Quake/HL ground accelerate: PM_Accelerate
		if wish_dir == Vector3.ZERO:
			return
		var current_speed := state.velocity.dot(wish_dir)
		var add_speed := wish_speed - current_speed
		if add_speed <= 0.0:
			return
		var accel_speed := minf(cfg.accelerate * state.accel_scale * state.friction_scale * delta * wish_speed, add_speed)
		state.velocity += accel_speed * wish_dir


	func air_accelerate(state: MovementState, wish_dir: Vector3,
			wish_speed: float, delta: float) -> void:
		## Quake/HL air accelerate: PM_AirAccelerate
		if wish_dir == Vector3.ZERO:
			return
		var current_speed := state.velocity.dot(wish_dir)
		var capped_wish := minf(wish_speed, cfg.air_speed_cap)
		var add_speed := capped_wish - current_speed
		if add_speed <= 0.0:
			return
		var accel_speed := minf(cfg.air_accelerate * delta * wish_speed, add_speed)
		state.velocity += accel_speed * wish_dir


	func clamp_velocity(state: MovementState) -> void:
		## sv_maxvelocity clamp — per-component, matching GoldSrc/Quake.
		## Vector-length clamping incorrectly reduces horizontal when vertical is large
		## (e.g. trigger_push at 4250 units would scale down forward speed).
		state.velocity.x = clampf(state.velocity.x, -cfg.max_velocity, cfg.max_velocity)
		state.velocity.y = clampf(state.velocity.y, -cfg.max_velocity, cfg.max_velocity)
		state.velocity.z = clampf(state.velocity.z, -cfg.max_velocity, cfg.max_velocity)


	func noclip_movement(state: MovementState, cmd) -> void:
		## Fly-through-walls debug mode.
		var cam_basis := Movement.camera_basis(cmd)
		var wish: Vector3 = cam_basis * Vector3(cmd.move_input.x, 0.0, cmd.move_input.y)
		if cmd.jump:
			wish.y += 1.0
		if cmd.crouch:
			wish.y -= 1.0
		if wish.length() > 0.001:
			# state.position is the body transform, so this moves the body directly.
			state.position += wish.normalized() * cfg.max_speed * 3.0 * float(cmd.delta)
		state.velocity = Vector3.ZERO


	func normal_movement(state: MovementState, cmd) -> void:
		## Ground/air movement — Quake/HL style.
		var wish_dir: Vector3 = Movement.calc_wish_dir(cmd)
		var max_speed: float = get_max_speed(state, cmd)
		var wish_speed: float = 0.0 if wish_dir == Vector3.ZERO else max_speed
		var dt: float = cmd.delta

		if state.on_floor:
			state.is_jumping = false
			if cmd.jump_just_pressed:
				state.velocity.y = cfg.jump_speed
				state.is_jumping = true
				air_accelerate(state, wish_dir, wish_speed, dt)
			else:
				apply_friction(state, dt)
				state.velocity.y -= cfg.gravity * state.gravity_scale * dt
				ground_accelerate(state, wish_dir, wish_speed, dt)
		else:
			state.velocity.y -= cfg.gravity * state.gravity_scale * dt
			air_accelerate(state, wish_dir, wish_speed, dt)


	func update_crouch(body, state: MovementState, cmd) -> void:
		## Update crouch state and collision shape.
		##
		## GoldSrc PM_Duck keeps the player's origin at the hull CENTRE: on the ground it
		## pulls the origin down by half the height change so the feet stay planted; in
		## the air it leaves the origin alone, so the feet rise instead — that rise is the
		## whole of the duck-jump, buying half a hull of extra reach over a plain jump.
		##
		## pmove's origin is the feet, so the grounded case falls out for free and only
		## the airborne lift has to be applied here.
		var grow := cfg.stand_height - cfg.crouch_height  # hull height a stand-up adds
		var duck_lift := grow * 0.5                       # ...and the feet's share of it
		if cmd.crouch and not state.is_crouched:
			# Always safe: the raised crouch hull is strictly inside the standing hull
			# it replaces, so this can never push the player into anything.
			if not state.on_floor:
				state.position.y += duck_lift
			state.is_crouched = true
		elif not cmd.crouch and state.is_crouched:
			# Standing grows the hull upward from the feet — except in mid-air, where the
			# feet drop back to where the duck lifted them from and it grows from there.
			# Ask about the volume at that offset rather than moving the body into it:
			# state.position writes through to the body, so probing by hand would mean
			# teleporting the player twice a tick to answer a hypothetical.
			var drop := 0.0 if state.on_floor else duck_lift
			if body.has_headroom(grow, Vector3.DOWN * drop):
				if drop != 0.0:
					state.position.y -= drop
				state.is_crouched = false

		var target_eye := cfg.crouch_eye if state.is_crouched else cfg.stand_eye
		var duck_speed := (cfg.stand_eye - cfg.crouch_eye) / cfg.duck_time
		state.eye_y = move_toward(state.eye_y, target_eye, duck_speed * float(cmd.delta))


	func walk_move(body, state: MovementState, cmd) -> bool:
		## GoldSrc PM_WalkMove — run both normal and step paths, take the better one.
		## Returns the correct on_floor state so simulate_tick can use it directly.
		## body.is_on_floor() is NOT reliable after this function — the step path's
		## elevated move_and_slide() corrupts it, and floor_snap_length=0 means
		## apply_floor_snap() can't repair it. The caller must use the return value.
		##
		## Wall-climbing protection: the step path must out-move the normal path
		## horizontally. Against a near-vertical wall both paths get blocked equally,
		## so step_h never exceeds normal_h and the normal path wins; a real stair
		## fully blocks the normal path but the step path clears it.
		##
		## Non-deterministic (two physics paths in one frame), but ClientMovement
		## ._replay_end_seq suppresses the follow-on chain corrections that non-
		## determinism used to cause, so the net result is at most one snap.
		var saved_pos: Vector3 = body.global_position
		var saved_vel: Vector3 = body.velocity

		# Normal path — always run first
		body.move_and_slide()
		var normal_pos: Vector3 = body.global_position
		var normal_vel: Vector3 = body.velocity
		var normal_on_floor: bool = body.is_on_floor()

		# Only attempt step path when there is meaningful horizontal velocity
		var wanted_h: float = Vector2(saved_vel.x, saved_vel.z).length() * float(cmd.delta)
		if wanted_h < 0.001:
			state.velocity = normal_vel
			return normal_on_floor if normal_on_floor else step_down(body, state)

		# Step path: lift → slide → drop
		body.global_position = saved_pos
		body.velocity = saved_vel
		if body.has_method("force_sync_physics"):
			body.force_sync_physics()
		body.move_and_collide(Vector3.UP * cfg.step_height)
		if body.has_method("force_sync_physics"):
			body.force_sync_physics()
		body.velocity = Vector3(saved_vel.x, 0.0, saved_vel.z)
		body.move_and_slide()
		if body.has_method("force_sync_physics"):
			body.force_sync_physics()
		var down_col = body.move_and_collide(Vector3.DOWN * (cfg.step_height + 0.01))
		var stepped_pos: Vector3 = body.global_position
		var step_rise: float = stepped_pos.y - saved_pos.y

		# A step is only a step if what it lands on is ground the player can stand on.
		# This used to accept anything past 0.5 — 60 degrees — so a slope too steep to
		# walk still counted, and the player ratcheted UP it a step per tick while
		# move_and_slide went on treating the same surface as a wall. ww_2fort's lift
		# hangs on four rope brushes pitched at 59.3 degrees, right in that gap: walking
		# on made the player climb the ropes in a series of hops. It is the same
		# threshold step_down already uses, and the body's own floor_max_angle.
		var landed_on_floor := false
		if down_col != null:
			landed_on_floor = (down_col as KinematicCollision3D).get_normal().dot(Vector3.UP) >= WALK_NORMAL_Y
		if step_rise >= cfg.min_step_rise and landed_on_floor:
			body.velocity = Vector3(saved_vel.x, 0.0, saved_vel.z)
			body.apply_floor_snap()
			state.velocity = body.velocity
			return true
		else:
			body.global_position = normal_pos
			body.velocity = normal_vel
			if body.has_method("force_sync_physics"):
				body.force_sync_physics()
			state.velocity = normal_vel
			return normal_on_floor if normal_on_floor else step_down(body, state)


	## GoldSrc PM_WalkMove closes with a downward trace, which is what keeps a player
	## attached to the ground when the floor falls away under them by less than
	## sv_stepsize in one tick — walking down stairs, and running down a ramp.
	##
	## Godot has no equivalent: move_and_slide's floor snap is floor_snap_length
	## (0.1 m by default) and a player at max_speed covers 0.13 m of ground per tick,
	## so every slope steeper than ~37° drops them into the air. They fall, touch the
	## ramp, get launched again — on_floor is false for most ticks of the descent, and
	## since jump is gated on it (normal_movement), most jump presses are silently
	## eaten. That is the "can't jump running down a ramp" bug.
	##
	## Only called when the tick began on the ground and is not a jump (simulate_tick
	## routes upward-moving ticks past walk_move entirely), so this can never re-ground
	## a player who is genuinely airborne or cut a jump short.
	func step_down(body, state: MovementState) -> bool:
		var before: Vector3 = body.global_position
		var col = body.move_and_collide(Vector3.DOWN * (cfg.step_height + 0.01))
		if col != null and (col as KinematicCollision3D).get_normal().dot(Vector3.UP) >= WALK_NORMAL_Y:
			# Landed: drop the accumulated fall speed the way a real floor contact
			# would, or it compounds each tick until the gap outgrows step_height.
			var v: Vector3 = body.velocity
			body.velocity = Vector3(v.x, 0.0, v.z)
			state.velocity = body.velocity
			return true
		# Nothing walkable within a step — a real ledge. Undo the probe.
		body.global_position = before
		if body.has_method("force_sync_physics"):
			body.force_sync_physics()
		return false


	func apply_head_delta(body, state: MovementState, cmd) -> void:
		## Roomscale VR: move the capsule by the player's physical head displacement
		## this tick, swept through collision. Runs identically on client predict,
		## client reconcile replay, and server (head_delta rides in the command), so
		## both ends agree on the resulting position. A plain move_and_collide (stop,
		## don't slide) is intentional: at a doorway you want the body to advance with
		## the head and simply halt against the frame, while the rig push-back lets the
		## view lean past the stuck capsule.
		state.head_consumed = Vector3.ZERO
		var hd: Vector2 = cmd.head_delta
		if hd == Vector2.ZERO:
			return
		var world: Vector3 = Basis(Vector3.UP, cmd.yaw) * Vector3(hd.x, 0.0, hd.y)
		if world.length_squared() < 1e-8:
			return
		var before: Vector3 = body.global_position
		body.move_and_collide(world)
		state.head_consumed = body.global_position - before


	func slide_move(body, motion: Vector3) -> void:
		## Move `motion`, collision-checked, without letting one blocked direction
		## cancel the others.
		##
		## move_and_collide is all-or-nothing along the whole vector: it stops on first
		## contact and the rest of the motion is simply lost. That is wrong for the
		## ride, because a mover's motion is rarely aligned with what a rider happens to
		## be leaning on. On ww_golem it broke the ride outright — the golem rises as it
		## strides, so the carry is back-and-up, and for a rider pressed against the
		## cockpit's rear wall the blocked BACKWARD component cancelled the LIFT with
		## it. They got none of the ride: the deck climbed away, they read as airborne,
		## the carry stopped entirely (it needs on_floor) and the golem walked out from
		## under them. Holding "back" anywhere along that wall sank the rider through
		## the deck and out of the golem within a couple of seconds.
		##
		## Vertical first, then horizontal, each as its own collision-checked move. The
		## lift is the part that keeps a rider standing on a climbing deck, so it must
		## not depend on the horizontal being free. Two moves rather than a slide
		## because the axes here are independent by construction — the ride is a floor
		## coming up under you and a wall coming at you, and neither answer should be
		## derived from the other's contact normal.
		var vertical := Vector3(0.0, motion.y, 0.0)
		var horizontal := Vector3(motion.x, 0.0, motion.z)
		if vertical != Vector3.ZERO:
			body.move_and_collide(vertical)
		if horizontal != Vector3.ZERO:
			body.move_and_collide(horizontal)


	func simulate_tick(body, state: MovementState, cmd) -> void:
		## Run one full movement tick — shared simulation kernel for client & server.
		## body: any object implementing the Body interface (e.g. GodotBody).

		# state.position is a view over the body transform — bind before anything reads it.
		state.bind_body(body)

		# Cache eye heights on state so restore() can snap without needing cfg.
		state._stand_eye = cfg.stand_eye
		state._crouch_eye = cfg.crouch_eye
		state._stand_height = cfg.stand_height
		state._crouch_height = cfg.crouch_height
		state.head_consumed = Vector3.ZERO
		# Fall-damage tracking: whether we were airborne entering the tick (so a
		# ground contact this tick is a landing) and the downward speed we carry in.
		var was_on_floor := state.on_floor
		state.landing_impact_speed = 0.0

		# GoldSrc pusher carry: displacement of the mover underfoot this tick,
		# applied as its own collision-checked move before locomotion. Riders of
		# moving brush entities (lifts, the golem) must be carried explicitly, and
		# this is the ONLY thing that carries them: GodotBody switches the body's
		# platform layers off so move_and_slide can't quietly carry them a second
		# time (see the note there — it did, and it flung ducked golem riders).
		# Runs before the move-lock early-out — a stunned rider still rides.
		if state.carry_motion != Vector3.ZERO:
			slide_move(body, state.carry_motion)
			state.carry_motion = Vector3.ZERO

		# Unstick backstop: eject from any solid the carry/pusher left the hull
		# embedded in (a mover motion the push couldn't stay ahead of, two parts
		# pinching). Collision-checked and applied even while move-locked/airborne —
		# a stunned or jumping rider must still be freed.
		if state.depenetration != Vector3.ZERO:
			slide_move(body, state.depenetration)
			state.depenetration = Vector3.ZERO

		# The other kind of unstick, and the reason it is its own field: a TELEPORT, deliberately
		# not swept. find_unstick_offset answers the pose a hull trace refuses every direction
		# from, and applying that answer as a sweep moves the hull exactly nowhere — measured, 20
		# consecutive "rescues" of one skeleton at an identical position, because slide_move asks
		# the same question that is already being refused. GoldSrc's PM_CheckStuck writes
		# pmove->origin for the same reason. Safe because the offset is a pose the search has
		# already verified can move, and small: the table starts at 1/8 unit and stops at 6.
		if state.unstick_offset != Vector3.ZERO:
			body.global_position += state.unstick_offset
			state.unstick_offset = Vector3.ZERO
			if body.has_method("force_sync_physics"):
				body.force_sync_physics()

		if state.is_move_locked:
			state.velocity = Vector3.ZERO
			body.velocity = Vector3.ZERO
			state.on_floor = body.is_on_floor()
			return

		body.yaw = cmd.yaw

		update_crouch(body, state, cmd)

		if cmd.noclip:
			noclip_movement(state, cmd)
			state.on_floor = false
			return

		if state.velocity_override_active:
			# Game-provided velocity (ladder, swimming, grapple, etc.) — skip normal physics.
			state.velocity = state.override_velocity
		else:
			normal_movement(state, cmd)

		clamp_velocity(state)

		# GoldSrc basevelocity: add push force to body for this physics tick only.
		# The push moves the player without permanently altering their state velocity —
		# it is subtracted back out after collisions (same as GoldSrc PM_Physics_Walking).
		body.velocity = state.velocity + state.base_velocity

		# walk_move returns the authoritative on_floor value — body.is_on_floor() is
		# unreliable after it because the step path's elevated move_and_slide() corrupts
		# the CharacterBody3D floor flag (and floor_snap_length=0 can't repair it).
		# Use the combined Y to decide: a large upward base_velocity means the player
		# is effectively airborne and should skip the step-aware walk path.
		# Downward speed carried into the move — the fall-impact speed if this move
		# lands us. Captured before the move zeroes velocity.y on ground contact.
		var pre_move_fall_speed: float = maxf(-state.velocity.y, 0.0)
		var on_floor_after_move: bool
		var combined_y: float = state.velocity.y + state.base_velocity.y
		if not state.velocity_override_active and state.on_floor and combined_y <= 0.0:
			on_floor_after_move = walk_move(body, state, cmd)
		else:
			body.move_and_slide()
			on_floor_after_move = body.is_on_floor()

		# Extract player's own velocity by removing the base contribution. Then sync
		# body.velocity so next tick's predict() reads the clean own-velocity.
		state.velocity = body.velocity - state.base_velocity
		state.base_velocity = Vector3.ZERO
		body.velocity = state.velocity
		state.on_floor = on_floor_after_move

		# Landed this tick (airborne → ground): expose the impact speed for the
		# server to turn into fall damage. Velocity-override ticks (ladder, water,
		# grapple) don't count — those aren't free falls.
		if on_floor_after_move and not was_on_floor and not state.velocity_override_active:
			state.landing_impact_speed = pre_move_fall_speed

		# Roomscale head tracking: nudge the capsule to follow the headset. Applied
		# after locomotion so it composes on top of stick movement; skipped for
		# move_locked / noclip via their early returns above.
		apply_head_delta(body, state, cmd)
