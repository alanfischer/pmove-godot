## GodotBody — wraps a CharacterBody3D to implement the Body interface
## used by Movement.simulate_tick / walk_move / update_crouch.
##
## Body interface methods:
##   move_and_slide() -> void
##   move_and_collide(motion: Vector3) -> KinematicCollision3D
##   is_on_floor() -> bool
##   set_collision_height(height: float, center_y: float) -> void
##   has_headroom(rise: float, from_offset := Vector3.ZERO) -> bool
##   can_move(motion: Vector3, from_offset := Vector3.ZERO) -> bool
##   global_position: Vector3  (get/set)
##   velocity: Vector3  (get/set)
##   yaw: float  (get/set)

class_name GodotBody extends RefCounted

var _body: CharacterBody3D
## Extra CollisionShape3Ds to resize with the hull. See _init.
var mirrored_shapes := PackedStringArray()
# Reused across calls rather than reallocated per query — has_headroom runs every
# tick a blocked player holds crouch released, and again for each command replayed
# during reconciliation.
var _test_params := PhysicsTestMotionParameters3D.new()
var _test_result := PhysicsTestMotionResult3D.new()


## `p_mirrored_shapes` are node paths, relative to the body, of extra CollisionShape3Ds that
## should follow the hull when crouching resizes it — a detector volume that has to keep matching
## the player's height, say. Each is resolved with get_node_or_null, so a path that is not there
## is simply skipped.
func _init(body: CharacterBody3D, p_mirrored_shapes := PackedStringArray()) -> void:
	_body = body
	mirrored_shapes = p_mirrored_shapes
	_test_params.recovery_as_collision = false
	_test_params.max_collisions = 4
	# pmove carries riders of moving brush entities itself (state.carry_motion), so
	# move_and_slide must not ALSO carry them. Godot applies platform_velocity * delta
	# at the START of move_and_slide, from state its previous call latched, then drops
	# that state when the call ends off-floor — so the displacement lands even though
	# get_platform_velocity() reads zero afterwards, which is what made this so hard to
	# see. Whether it latches at all depends on the floor contact, which can in turn depend
	# on the body's size: in the case that found this, a standing rider on a moving brush
	# entity never latched, a ducked one did, and got carried twice — drifting a step per
	# tick across the deck it was standing on and off the front of it.
	#
	# Zeroing the layers is what makes pmove's ownership of the carry true by
	# construction rather than by luck. It has to hold identically on client and server
	# or prediction diverges, and a body property does; a contact-shape coincidence
	# does not.
	_body.platform_floor_layers = 0
	_body.platform_wall_layers = 0


# --- Position / Velocity / Rotation ---

var global_position: Vector3:
	get: return _body.global_position
	set(v): _body.global_position = v

func force_sync_physics() -> void:
	## Force the physics server to use our current transform immediately.
	## Without this, move_and_slide after a position snap may use stale
	## broadphase data from the pre-snap position.
	PhysicsServer3D.body_set_state(
		_body.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM,
		_body.global_transform)

var velocity: Vector3:
	get: return _body.velocity
	set(v): _body.velocity = v

var yaw: float:
	get: return _body.rotation.y
	set(v): _body.rotation.y = v


# --- Movement methods ---

func move_and_slide() -> void:
	_body.move_and_slide()

func move_and_collide(motion: Vector3) -> KinematicCollision3D:
	return _body.move_and_collide(motion)

func is_on_floor() -> bool:
	return _body.is_on_floor()

func apply_floor_snap() -> void:
	_body.apply_floor_snap()


# --- Crouch support ---

func set_collision_height(height: float, center_y: float) -> void:
	var collision_shape: CollisionShape3D = _body.get_node_or_null("CollisionShape3D")
	if not collision_shape:
		return
	# Writing shape.height re-cooks the shape and invalidates the body's broadphase
	# AABB, so skip it when nothing changes. is_crouched now applies the hull on every
	# write — including the corrections that don't flip it — and those are the common
	# case. (This needs the capsule to be a per-body resource: duplicate the shape per body,
	# or every body using it resizes together.)
	if is_equal_approx(collision_shape.shape.height, height) \
			and is_equal_approx(collision_shape.position.y, center_y):
		return
	collision_shape.shape.height = height
	collision_shape.position.y = center_y
	for path in mirrored_shapes:
		var extra: CollisionShape3D = _body.get_node_or_null(path)
		if extra:
			extra.shape.height = height
			extra.position.y = center_y


func has_headroom(rise: float, from_offset := Vector3.ZERO) -> bool:
	## Is the space directly above the hull clear for `rise` metres, starting from
	## `from_offset` relative to where the body is now?
	##
	## Growing the hull upward sweeps exactly the volume this test sweeps: the taller
	## box is the current box swept up by the difference, and likewise for the capsule
	## the default-physics fallback uses (a capsule swept along its own axis is just a
	## longer capsule). So the caller asks about the volume it is about to occupy
	## without the body having to move there first.
	##
	## Swept rather than a static overlap query on purpose: body_test_motion is the
	## same call move_and_slide makes, so this cannot disagree with where the body
	## is actually allowed to be.
	if rise <= 0.0:
		return true
	var from := _body.global_transform.translated(from_offset)
	_test_params.margin = _body.safe_margin
	_test_params.max_collisions = 4   # this one reads the manifold (see can_move)

	# A non-zero offset asks about a pose the body is NOT currently in, and that pose
	# can be inside geometry. The sweep below cannot tell, because body_test_motion
	# DEPENETRATES before it casts: from a start buried in a floor it recovers up out
	# of it and then reports the space above that as clear. Which is how the airborne
	# stand-up got its answer — a rider crouched on a moving deck asks about the pose half a
	# hull lower, is told it is fine, drops 0.45 m into the deck, grows to the standing hull
	# and is thrown out of it. The deck was 0.39 m of solid there.
	#
	# Only the offset path pays for this. With no offset the start pose is where the
	# body already legally is, so there is nothing to check and the common grounded
	# case keeps its single query.
	if from_offset != Vector3.ZERO:
		_test_params.from = from
		_test_params.motion = Vector3.ZERO
		_test_params.recovery_as_collision = true
		PhysicsServer3D.body_test_motion(_body.get_rid(), _test_params, _test_result)
		_test_params.recovery_as_collision = false
		for i in _test_result.get_collision_count():
			# Resting on a surface reports depth up to the margin; anything past that
			# is real penetration, and no amount of headroom above makes that pose ok.
			if _test_result.get_collision_depth(i) > _body.safe_margin:
				return false

	_test_params.from = from
	_test_params.motion = Vector3.UP * rise
	PhysicsServer3D.body_test_motion(_body.get_rid(), _test_params, _test_result)
	# unsafe_fraction is how far the sweep got before hitting anything; 1.0 means the
	# whole rise is clear. travel is not the test — it carries the margin back-off and
	# any depenetration, neither of which says the ceiling is in the way.
	return _test_result.get_collision_unsafe_fraction() >= 1.0


func can_move(motion: Vector3, from_offset := Vector3.ZERO) -> bool:
	## Could the hull travel `motion` from `from_offset` relative to where it is now?
	##
	## Asked of a pose the body is not in, so the answer is about a hypothetical: the
	## offset search in [Movement].find_unstick_offset walks candidate poses with it
	## without moving the body to any of them.
	##
	## travel, not unsafe_fraction, unlike has_headroom above. A hull trace that cannot
	## answer from where it starts reports the whole motion blocked at fraction zero AND
	## no travel, and telling that apart from a clear sweep is the entire point of this
	## query: a body left inside the epsilon band a GoldSrc trace keeps its endpoints off
	## surfaces by cannot move, fall, or be rescued by steering. Half the motion is the
	## threshold so a margin-sized back-off does not read as being stuck.
	_test_params.from = _body.global_transform.translated(from_offset)
	_test_params.margin = _body.safe_margin
	_test_params.motion = motion
	_test_params.recovery_as_collision = false
	# Only travel is read, so asking for the manifold is work the server does and nobody uses —
	# and the offset search runs this once per candidate pose per axis. has_headroom puts it back.
	_test_params.max_collisions = 1
	PhysicsServer3D.body_test_motion(_body.get_rid(), _test_params, _test_result)
	return _test_result.get_travel().length() >= motion.length() * 0.5
