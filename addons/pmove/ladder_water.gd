## Ladders and water: GoldSrc PM_LadderMove, PM_WaterMove and PM_CheckWaterJump.
##
## These ride the kernel's velocity override rather than living in simulate_tick, because what
## counts as a ladder or as water is the game's to say. The game finds them (a volume, a brush
## flag, a submersion probe) and hands a [Driver] the answer each tick; the driver picks the
## velocity and writes it into the tick's MovementModifiers, so replay stays data-driven.
##
## The static functions are the moves themselves, for a caller that makes its own decisions —
## a monster swims where it is walking rather than where a camera looks.

const Movement = preload("res://addons/pmove/movement.gd")
const _LadderWater = preload("res://addons/pmove/ladder_water.gd")  # for Driver, an inner class

const WATERJUMP_TIME := 0.6          # seconds the launch overrides the swim (HL waterjumptime)
const WATERJUMP_UP := 8.5            # upward launch speed (~1.8 m rise — clears a step-tall bank)
const WATERJUMP_FORWARD := 8.0       # horizontal launch toward the bank (= max_speed)
const WATERJUMP_SINK_CUTOFF := -4.5  # don't launch while plunging in (HL: velocity[2] < -180)
const WATERJUMP_REACH := 0.9         # forward probe distance (hull radius + arm's reach)
const WATERJUMP_LOW_Y := 0.9         # low probe height — a bank must block us here (near surface)
const WATERJUMP_PROBE_STEP := 0.35   # probe spacing above head height, for a caller with reach
const WATERJUMP_CLEAR := 0.3         # extra rise over the lip found, so the launch lands ON it

## Reused across calls and across swimmers — every swimmer runs the probe twice a tick.
static var _waterjump_ray: PhysicsRayQueryParameters3D = null


## The player's per-tick choice between ladder, climb-out and swim, and the one piece of state
## that choice needs across ticks: the climb-out clock. One per body.
class Driver:
	## Speed past which a ladder lets go, so a blast can knock a climber off. GoldSrc has none.
	var ladder_knockoff_speed := INF
	## What the climb-out probe counts as a bank.
	var wall_mask := 0xFFFFFFFF
	## Counts down while a climb-out launch is in flight.
	var waterjump_time := 0.0

	## `on_ladder` with the ladder's outward `ladder_normal`; `in_water` is GoldSrc's waterlevel 2,
	## deep enough to swim. `space` is for the climb-out probe. Call every tick the body moves.
	func apply(mods, cfg, state, cmd, on_ladder: bool, ladder_normal: Vector3, in_water: bool,
			space: PhysicsDirectSpaceState3D) -> void:
		# Aged every tick, in the water or not — the launch leaves the water at once, and a
		# stale clock would hold off the swim on the way back in.
		if waterjump_time > 0.0:
			waterjump_time = 0.0 if state.on_floor else maxf(waterjump_time - float(cmd.delta), 0.0)

		if on_ladder and state.velocity.length() < ladder_knockoff_speed:
			mods.velocity_override_active = true
			if cmd.jump:
				mods.override_velocity = _LadderWater.ladder_dismount_velocity(
						cfg, state.on_floor, ladder_normal)
			else:
				mods.override_velocity = _LadderWater.ladder_velocity(
						cfg, state.is_crouched, state.on_floor, cmd, ladder_normal)
		elif in_water:
			if waterjump_time > 0.0:
				# Mid-launch: air movement carries the launch over the bank. PM_PlayerMove's
				# waterjump branch never reaches PM_Jump, so neither jumps nor latches.
				mods.skip_jump = true
				return
			var launch := _LadderWater.water_jump(space, cfg, state.position,
					Movement.calc_wish_dir(cmd), state.velocity.y, 0.0, wall_mask)
			mods.velocity_override_active = true
			if launch != Vector3.ZERO:
				waterjump_time = _LadderWater.WATERJUMP_TIME
				mods.override_velocity = launch
			else:
				mods.override_velocity = _LadderWater.water_velocity(
						cfg, state.velocity, state.is_crouched, cmd)

	func reset() -> void:
		waterjump_time = 0.0


## Climb where you look: input along the ladder's face becomes up and down. ZERO with no input,
## which holds the climber in place.
static func ladder_velocity(
		cfg, is_crouched: bool, on_floor: bool, cmd, ladder_normal: Vector3) -> Vector3:
	var speed: float = cfg.ladder_speed
	if is_crouched:
		speed *= cfg.duck_mult

	var mi: Vector2 = cmd.move_input
	if mi == Vector2.ZERO:
		return Vector3.ZERO

	var cam_basis := Movement.camera_basis(cmd)
	var wish_vel: Vector3 = (-cam_basis.z) * (-mi.y * speed) + cam_basis.x * (mi.x * speed)

	var n := ladder_normal
	var perp: Vector3 = Vector3.UP.cross(n)
	if perp.length_squared() < 0.001:
		return wish_vel
	perp = perp.normalized()

	var normal_comp: float = wish_vel.dot(n)
	var lateral: Vector3 = wish_vel - normal_comp * n
	var result: Vector3 = lateral + (-normal_comp) * n.cross(perp)

	if on_floor and normal_comp > 0:
		result += n * cfg.ladder_speed

	return result


## Jumping off a ladder pushes away from it (270 u/s), with a jump's rise from the floor.
static func ladder_dismount_velocity(cfg, on_floor: bool, ladder_normal: Vector3) -> Vector3:
	var vel: Vector3 = ladder_normal * cfg.ladder_jump
	if on_floor:
		vel.y = cfg.jump_speed
	return vel


## Swim where you look; jump rises, crouch sinks.
static func water_velocity(cfg, current_velocity: Vector3, is_crouched: bool, cmd) -> Vector3:
	var speed: float = cfg.water_speed
	if is_crouched:
		speed *= cfg.duck_mult

	var cam_basis := Movement.camera_basis(cmd)
	var wish_vel: Vector3 = (-cam_basis.z) * (-cmd.move_input.y * speed) \
			+ cam_basis.x * (cmd.move_input.x * speed)
	if cmd.jump:
		wish_vel.y += speed
	if cmd.crouch:
		wish_vel.y -= speed

	return swim(cfg, current_velocity, wish_vel, float(cmd.delta))


## The swim itself: water drag, then acceleration toward `wish_vel`.
static func swim(cfg, current_velocity: Vector3, wish_vel: Vector3, delta: float) -> Vector3:
	return drag_accelerate(current_velocity, wish_vel, delta, cfg.water_friction, cfg.accelerate)


## Drag proportional to speed, then acceleration toward `wish_vel` — the swim's rule, for any
## free 3D move through a medium (a game's flight, say) that only differs in its drag.
static func drag_accelerate(current_velocity: Vector3, wish_vel: Vector3, delta: float,
		drag: float, accelerate: float) -> Vector3:
	var vel := current_velocity
	var cur_speed := vel.length()
	if cur_speed > 0.01:
		var drop: float = cur_speed * drag * delta
		vel *= maxf(cur_speed - drop, 0.0) / cur_speed

	if wish_vel.length_squared() > 0.001:
		var wish_speed := wish_vel.length()
		var wish_dir := wish_vel / wish_speed
		var add_speed := wish_speed - vel.dot(wish_dir)
		if add_speed > 0:
			vel += minf(accelerate * delta * wish_speed, add_speed) * wish_dir

	return vel


## A launch (up + forward) that pops a swimmer over a bank, or ZERO with nothing to climb: a low
## probe must hit a wall while a head-height one stays clear — a lip, not a cliff. `feet` is the
## hull's floor point, `dir` the horizontal direction swum (ZERO = not trying), `vel_y` its rise.
##
## `reach` probes on above head height in WATERJUMP_PROBE_STEP steps and sizes the launch to the
## lip it finds. Zero is GoldSrc's rule exactly: two probes, one launch speed.
static func water_jump(space: PhysicsDirectSpaceState3D, cfg, feet: Vector3, dir: Vector3,
		vel_y: float, reach := 0.0, wall_mask := 0xFFFFFFFF) -> Vector3:
	if space == null or dir == Vector3.ZERO:
		return Vector3.ZERO
	if vel_y < WATERJUMP_SINK_CUTOFF:
		return Vector3.ZERO
	if not _probe_wall(space, feet + Vector3(0.0, WATERJUMP_LOW_Y, 0.0), dir, wall_mask):
		return Vector3.ZERO
	if not _probe_wall(space, feet + Vector3(0.0, cfg.stand_height, 0.0), dir, wall_mask):
		return dir * WATERJUMP_FORWARD + Vector3(0.0, WATERJUMP_UP, 0.0)
	var h: float = cfg.stand_height + WATERJUMP_PROBE_STEP
	while h <= reach:
		if not _probe_wall(space, feet + Vector3(0.0, h, 0.0), dir, wall_mask):
			# Clear at h, blocked below it: the lip is in that step. Rise enough to land on it.
			return dir * WATERJUMP_FORWARD \
					+ Vector3(0.0, sqrt(2.0 * cfg.gravity * (h + WATERJUMP_CLEAR)), 0.0)
		h += WATERJUMP_PROBE_STEP
	return Vector3.ZERO


static func _probe_wall(space: PhysicsDirectSpaceState3D, origin: Vector3, dir: Vector3,
		mask: int) -> bool:
	if _waterjump_ray == null:
		_waterjump_ray = PhysicsRayQueryParameters3D.new()
	_waterjump_ray.collision_mask = mask
	_waterjump_ray.from = origin
	_waterjump_ray.to = origin + dir * WATERJUMP_REACH
	return not space.intersect_ray(_waterjump_ray).is_empty()
