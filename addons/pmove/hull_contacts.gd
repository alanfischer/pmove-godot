## What the hull is touching, and what moving geometry does about it: GoldSrc's pushers for Godot.
##
## Movers are AnimatableBody3Ds. Once per physics frame, apply() probes the hull and writes the
## tick's corrections into a MovementModifiers (or anything with the same three fields):
##   carry_motion   — the mover underfoot's displacement (the ride), plus any mover advancing into
##                    the hull from another side (the push);
##   depenetration  — a capped nudge out of whatever the hull is embedded in;
##   unstick_offset — PM_CheckStuck's teleport, for a hull no sweep can leave.
## As modifiers they are recorded and replayed with the command, never re-decided on replay.
##
## The body's own platform layers must be off, as GodotBody leaves them, or Godot carries the
## rider a second time.

const Movement = preload("res://addons/pmove/movement.gd")

## Pinned and freed: `offset` is how far the hull was moved.
signal unstuck(at: Vector3, offset: Vector3)
## Pinned, and nothing in the search frees it — a map or mover problem worth logging.
signal pinned(at: Vector3)

## A single-frame yaw larger than this is a teleport/reset, not a rotating mover.
const MAX_CARRY_YAW := PI / 4
## How long a mover's baseline survives without contact — covers a one-tick flicker (jump, stride
## bob) without keeping every mover ever touched.
const MOVER_MEMORY_FRAMES := 10
## Contact normals steeper (more upward) than this are a floor/ramp the hull rests on — never
## unstick off those, or a resting body would hover.
const SUPPORT_NORMAL_Y := 0.7
## Ceiling on the per-tick nudge out of a non-support penetration, so a deep embed clears smoothly
## over a few ticks instead of being launched out in one.
const DEPEN_STEP := 0.1

## A mover that jumps further than this in one frame was placed, not moved, and carries nothing.
var teleport_distance := 12.0
## Metres per GoldSrc unit, the scale the unstick search's offsets are written in.
var unit := 0.025
## What the ride's fallback ground probe hits; 0 means the character's own collision_mask.
var ground_mask := 0
## Optional `func(mover) -> Array`: [velocity, angular_velocity], or [] for a mover that publishes
## none. For movers whose transform lags their motion, such as interpolated network entities: the
## carry follows the velocity and is corrected toward the transform. Without it the carry is the
## transform's own frame-to-frame change.
var mover_velocity := Callable()

## Yaw (radians) the mover underfoot turned this tick. A rider adds it to its view to turn with it.
var carry_yaw_delta: float:
	get: return _carry_yaw_delta

var _character: CharacterBody3D
var _carry_query := PhysicsShapeQueryParameters3D.new()
var _carry_yaw_delta := 0.0

# Zero-motion body_test_motion (not a shape query) reports the recovery MANIFOLD, so ground and
# obstruction arrive as separate contacts instead of one elected winner, and it tests the body's
# live shapes so it tracks crouch automatically.
var _hull_motion_params := PhysicsTestMotionParameters3D.new()
var _hull_motion_result := PhysicsTestMotionResult3D.new()
var _probe_frame := -1
# The probe's manifold, split once and read by both halves of the tick.
# Contacts that are NOT holding us up — the pusher + unstick set.
var _contacts: Array = []
# Whether anything at all holds us up, and the mover among those if there is one. The ride reads
# both: a support contact means the probe has already answered "what am I standing on", and only
# its absence sends the carry to a probe of its own.
var _supported := false
var _support_mover: AnimatableBody3D = null
# Penetration into each mover the hull touched, keyed by instance id, rebuilt by every probe.
var _mover_obstruction: Dictionary = {}
var _mover_obstruction_frame := -1
# Every mover recently touching the hull (under/beside/above), keyed by instance id, since a
# corner-wedged hull can touch several surfaces across several bodies (a walking mover's arm
# against its own torso). Both the ride and the pusher measure against these.
var _movers: Dictionary = {}
# When to ask whether the hull is pinned. Only advanced on live ticks: replay reuses the stored
# modifiers, so it never re-runs the search.
var _unstick := Movement.UnstickWatch.new()


func _init(character: CharacterBody3D) -> void:
	_character = character
	var carry_sphere := SphereShape3D.new()
	carry_sphere.radius = 0.3
	_carry_query.shape = carry_sphere
	_carry_query.exclude = [character.get_rid()]
	_hull_motion_params.motion = Vector3.ZERO
	_hull_motion_params.recovery_as_collision = true
	_hull_motion_params.max_collisions = 4


## This tick's ride, push, depenetration and unstick, into `mods`. `body` is the adapter the
## simulation drives (GodotBody), for the unstick search; null skips unstick.
##
## Only the first call in a physics frame does anything: a server batching N commands into one
## frame still saw the world move once, and everything here is a position delta, so the later
## commands must contribute zero rather than re-apply it.
func apply(mods, state: Movement.MovementState, cmd, body) -> void:
	if not _probe_hull():
		return
	mods.carry_motion = _compute_mover_carry(state, float(cmd.delta))
	_apply_hull_corrections(mods, float(cmd.delta), cmd, body)


## How deep the hull is inside `mover`, per the last probe; 0.0 for a mover it never touched, -1.0
## for no measurement at all (the caller holds its decision on that). A mover asks this to decide
## it is Blocked. A sample one frame old counts, since nothing orders a mover's _physics_process
## against the character's.
func mover_obstruction(mover: Object) -> float:
	if mover == null or Engine.get_physics_frames() - _mover_obstruction_frame > 1:
		return -1.0
	return float(_mover_obstruction.get(mover.get_instance_id(), 0.0))


## Forget the unstick clock — for a body that has just been teleported or placed.
func reset() -> void:
	_unstick.reset()


## The world-space displacement of `point` between two mover transforms (translation + rotation
## sweep in one step), teleport-gated: a jump past teleport_distance is a reset, not motion, and
## yields ZERO so riders aren't yanked across the map. Shared by the ride and the pusher.
func _gated_mover_delta(prior_xform: Transform3D, new_xform: Transform3D, point: Vector3) -> Vector3:
	var moved := new_xform * (prior_xform.affine_inverse() * point) - point
	if moved.length_squared() > teleport_distance * teleport_distance:
		return Vector3.ZERO
	return moved


## Bring every remembered mover's baseline up to the current frame and drop stale ones.
## Baselines must survive a brief contact lapse (jump, stride bob) rather than reset — otherwise
## the rider eats a whole tick of the mover's motion when contact resumes, or (if left stale
## instead) the whole airborne accumulation applies at once. Evicted by age too, so a body that
## rides several lifts doesn't leak entries.
func _refresh_movers() -> void:
	var frame := Engine.get_physics_frames()
	for id in _movers.keys():
		var m := instance_from_id(id)
		if not (m is Node3D and is_instance_valid(m)) \
				or frame - int(_movers[id]["seen"]) > MOVER_MEMORY_FRAMES:
			_movers.erase(id)
			continue
		_movers[id]["xform"] = (m as Node3D).global_transform


## The baseline for `id` as of last frame, or null if we have none to measure against.
func _mover_baseline(id: int):
	var e = _movers.get(id)
	return e["xform"] if e != null else null


## Note contact with `id` this frame so it isn't evicted. Deliberately does NOT advance the
## baseline — _refresh_movers does that once, at end of frame. If it advanced here, the carry
## (which runs first) would move the baseline and the pusher, reading the same body moments
## later, would measure zero motion.
func _mover_touch(id: int, xform: Transform3D) -> void:
	var e = _movers.get(id)
	if e == null:
		_movers[id] = { "xform": xform, "seen": Engine.get_physics_frames() }
	else:
		e["seen"] = Engine.get_physics_frames()


## Fallback contact test for the ride, for the frames the hull probe comes back with nothing
## holding us up while the simulation still says we are grounded — a deck that dropped out from
## under us faster than we fall is more than safe_margin away, yet it is still the floor we are
## riding. Losing that tick's carry is permanent slip: the velocity path corrects toward the
## measured delta by at most DEPEN_STEP, from a baseline that refreshes with or without contact,
## so nothing gives the missed displacement back.
##
## Sphere overlap, not a ray: brush floors are convex-decomposed and a knife-edge ray can thread a
## seam between pieces and miss the floor entirely. Raised 0.1 m and 0.3 m wide so it still
## reaches a deck that has fallen away.
func _sphere_ground(pos: Vector3) -> AnimatableBody3D:
	_carry_query.collision_mask = ground_mask if ground_mask != 0 else _character.collision_mask
	_carry_query.transform = Transform3D(Basis.IDENTITY, pos + Vector3(0.0, 0.1, 0.0))
	var hits: Array = _character.get_world_3d().direct_space_state.intersect_shape(_carry_query, 6)
	for h in hits:
		if h.get("collider") is AnimatableBody3D:
			return h["collider"]
	return null


## GoldSrc basevelocity-style carry. With mover_velocity, the displacement comes from the mover's
## own published velocity — exact the instant it arrives, unlike diffing a position pair that lags
## by the interpolation delay — at point-velocity v + ω × (point - origin) so an off-centre rider
## on a rotating mover still carries correctly. That open-loop estimate can drift from the mover's
## actual transform delta, so it is corrected toward the measured delta every tick, bounded by
## DEPEN_STEP so real divergence clears over a few ticks instead of snapping. Without one, the
## carry is the transform pair's diff.
##
## The yaw the rider's view rides is always the measured pair, published velocity or not.
func _compute_mover_carry(state: Movement.MovementState, delta: float) -> Vector3:
	_carry_yaw_delta = 0.0
	if not state.on_floor:
		# Airborne: no carry, but the baseline in _movers stays fresh so the landing tick
		# measures against a one-frame-old pose instead of losing a tick.
		return Vector3.ZERO
	var pos: Vector3 = _character.global_position
	# The hull probe already found what we rest on, so in the common case — riding a deck, or
	# standing on plain world — the ride costs no query of its own.
	var ground: AnimatableBody3D = _support_mover
	if ground == null and not _supported:
		ground = _sphere_ground(pos)
	if not ground:
		return Vector3.ZERO
	var mover_id: int = ground.get_instance_id()
	var xform: Transform3D = ground.global_transform
	var carry := Vector3.ZERO
	var yaw := 0.0
	var prev = _mover_baseline(mover_id)
	# The measured pair, once: the velocity path corrects toward it and the view rides it. ZERO on
	# a teleport as well as on a mover that did not move, and only the first must suppress the
	# yaw — a map reset must not spin a rider's view.
	var true_delta := Vector3.ZERO
	var pair_moved := false
	if prev != null:
		true_delta = _gated_mover_delta(prev, xform, pos)
		pair_moved = true_delta != Vector3.ZERO
	var published: Array = mover_velocity.call(ground) if mover_velocity.is_valid() else []
	if not published.is_empty():
		var target_vel: Vector3 = published[0]
		var target_angvel: Vector3 = published[1]
		carry = (target_vel + target_angvel.cross(pos - xform.origin)) * delta
		if prev != null:
			carry += (true_delta - carry).limit_length(DEPEN_STEP)
	elif pair_moved:
		carry = true_delta
	# The view rides the measured pair even when a velocity is published, never the angular
	# velocity: that is a wall-clock rate spent on the simulation clock, and nothing corrects it
	# afterwards the way the linear carry is corrected, so its error is a heading random walk a
	# rider can never shed.
	if pair_moved:
		yaw = wrapf(xform.basis.get_euler().y - (prev as Transform3D).basis.get_euler().y, -PI, PI)
	if absf(yaw) <= MAX_CARRY_YAW:
		_carry_yaw_delta = yaw
	_mover_touch(mover_id, xform)
	return carry


## One zero-motion full-hull rest probe, split into what holds us up and what doesn't, for both
## the ride and the pusher/unstick. Returns false when this frame's probe already ran.
##
## Surfaces we rest ON are separated by normal, not collider id: a walking mover's floor and
## ceiling can be ONE AnimatableBody3D, so id-based exclusion can't tell them apart. That needs a
## probe that reports BOTH contacts when touching both — get_rest_info can't (one contact per
## collider; it used to elect floor or wall arbitrarily, depending on the crouch hull's size).
## body_test_motion's recovery manifold reports ground and obstruction as separate contacts.
func _probe_hull() -> bool:
	var frame := Engine.get_physics_frames()
	if frame == _probe_frame:
		return false
	_probe_frame = frame
	_mover_obstruction.clear()
	_mover_obstruction_frame = frame
	_contacts.clear()
	_supported = false
	_support_mover = null
	_hull_motion_params.from = _character.global_transform
	_hull_motion_params.margin = _character.safe_margin
	PhysicsServer3D.body_test_motion(_character.get_rid(), _hull_motion_params, _hull_motion_result)

	for i in _hull_motion_result.get_collision_count():
		var n := _hull_motion_result.get_collision_normal(i)
		var hit_id := _hull_motion_result.get_collider_id(i)
		var hit := instance_from_id(hit_id)
		var depth := _hull_motion_result.get_collision_depth(i)
		# Before the filters below, because a plat crushing its own rider into a ceiling shows up
		# ONLY as a growing support contact. Max per mover, since a deck and a wall can be one body.
		if hit is AnimatableBody3D:
			_mover_obstruction[hit_id] = maxf(float(_mover_obstruction.get(hit_id, 0.0)), depth)
		# Character-on-character overlap is move_and_slide's business, not unsticking's — and a
		# head you happen to be standing on is nobody's floor.
		if hit is CharacterBody3D:
			continue
		if n.y > SUPPORT_NORMAL_Y:
			# What holds us up is the ride's business: pushing along an up normal would ratchet a
			# rising floor every up-bob.
			_supported = true
			if _support_mover == null and hit is AnimatableBody3D:
				_support_mover = hit
			continue
		# Every non-support contact, not just the deepest — the pusher needs each surface, since
		# the deepest right now isn't necessarily the one about to run the body over.
		_contacts.append({
			"normal": n,
			"point": _hull_motion_result.get_collision_point(i),
			"collider": hit,
			"id": hit_id,
			"depth": depth,
		})
	return true


## GoldSrc PM_CheckStuck, for the pose the depth-proportional push cannot answer: a hull left
## inside the DIST_EPSILON band a hull trace keeps its endpoints off surfaces by reports one
## zero-depth support contact, so there is no depth to push along, and from in there every sweep
## is refused, including straight back out. The body can neither walk nor fall.
##
## unstick_offset, not depenetration: the kernel teleports this one, uncapped — see simulate_tick.
func _apply_unstick(mods, delta: float, cmd, body) -> void:
	if body == null:
		return
	var here: Vector3 = _character.global_position
	# move_input as the intent: a body nobody is steering has no symptom to rescue, and without
	# this gate one standing still re-asks the question every STALL_TIME for as long as it stands.
	var offset := _unstick.poll(body, here, delta, unit, cmd.move_input != Vector2.ZERO)
	if offset == Vector3.ZERO:
		if _unstick.gave_up():
			pinned.emit(here)
		return
	mods.unstick_offset = offset
	unstuck.emit(here, offset)


## The "push" half of a GoldSrc pusher plus the unstick backstop, from the probe's non-support
## contacts:
##   carry_motion += push — a mover sweeping INTO the hull ejects the body ahead of its advancing
##           surface (a descending ceiling shoves a jumping rider down instead of swallowing it).
##   depenetration — last-resort nudge out of the penetration.
func _apply_hull_corrections(mods, delta: float, cmd, body) -> void:
	# The deepest contact that is NOT holding us up.
	var normal := Vector3.ZERO
	var best_depth := 0.0
	for c in _contacts:
		var depth: float = c["depth"]
		if normal == Vector3.ZERO or depth > best_depth:
			best_depth = depth
			normal = c["normal"]
	if normal == Vector3.ZERO:
		_refresh_movers()
		_apply_unstick(mods, delta, cmd, body)
		return
	# Correct the measured penetration, capped at DEPEN_STEP — an uncapped nudge treats a 2 mm
	# graze and a 10 cm embed identically, so merely leaning on a wall buzzes in and out.
	mods.depenetration = normal * minf(DEPEN_STEP, best_depth)
	# Pusher: every mover advancing into the hull, from any side.
	for c in _contacts:
		var collider: Object = c["collider"]
		if not collider is AnimatableBody3D:
			continue
		var mover_id: int = c["id"]
		var xform: Transform3D = collider.global_transform
		var contact_normal: Vector3 = c["normal"]
		var moved := Vector3.ZERO
		var prev = _mover_baseline(mover_id)
		if prev != null and not xform.is_equal_approx(prev):
			moved = _gated_mover_delta(prev, xform, c["point"])
		if moved != Vector3.ZERO:
			# Push by what this surface does OVER the ride's carry, not the raw displacement: a
			# deck and its wall can be the same body, and without subtracting the carry the wall's
			# push would double the deck's motion. A genuine push (a ceiling over a rider standing
			# on static ground) has no carry to subtract.
			var relative: Vector3 = moved - mods.carry_motion
			var into := relative.dot(contact_normal)  # >0 only when the surface gains on us
			if into > 0.0:
				mods.carry_motion += contact_normal * into
		_mover_touch(mover_id, xform)
	# Baselines advance exactly once, here, after both the ride and the pusher have measured
	# against last frame's.
	_refresh_movers()
