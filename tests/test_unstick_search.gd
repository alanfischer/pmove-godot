extends "res://tests/suite.gd"

const Movement = preload("res://addons/pmove/movement.gd")

## The offset search behind both unstick callers. No physics server: a fake body answers
## can_move from a declared set of free poses, which is the whole point of the search being a
## pure static over the Body interface.


## Answers can_move by looking the candidate pose up in `free`. A pose not listed is pinned in
## every direction, which is the state the search exists to escape.
class PinnedBody:
	var global_position := Vector3.ZERO
	## Offsets (metres, from the current pose) that can move. ZERO absent = pinned where it is.
	var free: Array[Vector3] = []
	var asked: Array[Vector3] = []

	func can_move(_motion: Vector3, from_offset := Vector3.ZERO) -> bool:
		asked.append(from_offset)
		for f in free:
			if f.distance_to(from_offset) < 0.0001:
				return true
		return false


const UNIT := 0.025   # metres per GoldSrc unit (1 unit = 1/40 m)


## STUCK_OFFSETS is generated from a rule rather than transcribed, so the order it produces is
## worth pinning: the search is smallest-first by construction, and a reordering would silently
## make it teleport a stuck body where it used to nudge one.
func test_stuck_offsets_are_ordered_smallest_first() -> void:
	var offs := Movement.STUCK_OFFSETS
	assert_eq(offs.size(), 20, "six single-axis nudges, eight corners, six big moves")

	var q := Movement.STUCK_QUANTUM
	assert_eq(offs[0], Vector3(0.0, q, 0.0), "the first candidate is one quantum up")
	assert_eq(offs[1], Vector3(0.0, -q, 0.0), "then one quantum down")
	assert_eq(offs[6], Vector3(q, q, q), "the cube corners follow the single axes")
	assert_eq(offs[13], Vector3(-q, -q, -q), "and run to the opposite corner")
	assert_eq(offs[14], Vector3(0.0, 1.0, 0.0), "the big moves come last")
	assert_eq(offs[19], Vector3(0.0, 0.0, -2.0), "ending two units lateral")

	# The ordering contract: every cheap nudge is tried before any visible displacement. Note it
	# is NOT a sort by magnitude — the 6-unit lift at 15 precedes the 2-unit lateral moves after
	# it, because a hull stuck in a seam is far more often freed upward than sideways, and a
	# wasted query costs more than a slightly larger push.
	var biggest_nudge := 0.0
	for i in 14:
		biggest_nudge = maxf(biggest_nudge, offs[i].length())
	assert_almost_eq(biggest_nudge, Vector3(q, q, q).length(), 0.0001,
		"the nudge group reaches no further than a cube corner")
	for i in range(14, offs.size()):
		assert_true(offs[i].length() > biggest_nudge,
			"candidate %d is a big move, tried only after every nudge" % i)


func test_pinned_pose_is_detected() -> void:
	var body := PinnedBody.new()
	assert_true(Movement.is_pinned(body), "no direction free = pinned")


func test_one_free_direction_is_not_pinned() -> void:
	var body := PinnedBody.new()
	body.free = [Vector3.ZERO]   # can move from where it is
	assert_false(Movement.is_pinned(body), "a pose that can move anywhere is not pinned")


func test_finds_the_smallest_offset_that_frees_it() -> void:
	var body := PinnedBody.new()
	# Both a little move and a big one would work; the little one must win.
	body.free = [Vector3(0.0, 0.125, 0.0) * UNIT, Vector3(0.0, 6.0, 0.0) * UNIT]
	var got := Movement.find_unstick_offset(body, UNIT)
	assert_vec3_almost_eq(got, Vector3(0.0, 0.125, 0.0) * UNIT, 0.0001,
		"the first table entry that frees the hull wins")


func test_falls_through_to_a_big_move() -> void:
	var body := PinnedBody.new()
	body.free = [Vector3(2.0, 0.0, 0.0) * UNIT]
	var got := Movement.find_unstick_offset(body, UNIT)
	assert_vec3_almost_eq(got, Vector3(2.0, 0.0, 0.0) * UNIT, 0.0001,
		"a hull only a big move frees gets the big move")


func test_no_free_pose_returns_zero() -> void:
	var body := PinnedBody.new()
	var got := Movement.find_unstick_offset(body, UNIT)
	assert_vec3_almost_eq(got, Vector3.ZERO, 0.0001,
		"buried with no way out reports ZERO rather than nudging blind")


func test_offsets_scale_with_the_unit() -> void:
	var body := PinnedBody.new()
	body.free = [Vector3(0.0, 0.125, 0.0) * 0.1]
	var got := Movement.find_unstick_offset(body, 0.1)
	assert_vec3_almost_eq(got, Vector3(0.0, 0.125, 0.0) * 0.1, 0.0001,
		"the table is in GoldSrc units; `unit` converts it")


func test_search_never_moves_the_body() -> void:
	var body := PinnedBody.new()
	body.free = [Vector3(0.0, 1.0, 0.0) * UNIT]
	Movement.find_unstick_offset(body, UNIT)
	assert_vec3_almost_eq(body.global_position, Vector3.ZERO, 0.0001,
		"the search reports an offset; applying it is the caller's business")


func test_is_pinned_accepts_a_candidate_offset() -> void:
	var body := PinnedBody.new()
	body.free = [Vector3(0.0, 0.125, 0.0) * UNIT]
	assert_true(Movement.is_pinned(body), "pinned where it stands")
	assert_false(Movement.is_pinned(body, Vector3(0.0, 0.125, 0.0) * UNIT),
		"and not pinned at the candidate — which is what lets the search reuse this")


func test_down_is_probed_last() -> void:
	# A candidate near a floor refuses DOWN, so asking first spends a wasted query on nearly
	# every entry in the table.
	assert_eq(Movement.PROBE_AXES[Movement.PROBE_AXES.size() - 1], Vector3.DOWN,
		"DOWN belongs at the end of PROBE_AXES")


func test_little_moves_are_tried_before_big_ones() -> void:
	var body := PinnedBody.new()
	Movement.find_unstick_offset(body, UNIT)
	# Every 1/8-unit candidate must have been asked about before the first whole-unit one.
	var first_big := -1
	for i in body.asked.size():
		if body.asked[i].length() > 0.5 * UNIT:
			first_big = i
			break
	assert_gt(first_big, 0, "a big move was tried, and not first")
	for i in first_big:
		assert_lt(body.asked[i].length(), 0.5 * UNIT,
			"nothing larger than a little move may be tried before entry %d" % first_big)


## The kernel's half: the offset has to arrive as a teleport, and it has to replay.
class TeleportBody:
	var global_position := Vector3.ZERO
	var velocity := Vector3.ZERO
	var yaw := 0.0
	var slides := 0
	var synced := 0

	func move_and_slide() -> bool:
		slides += 1
		return false

	func move_and_collide(_motion: Vector3, _test_only := false, _margin := 0.001):
		slides += 1
		return null

	func is_on_floor() -> bool: return true
	func apply_floor_snap() -> void: pass
	func set_collision_height(_h: float, _c: float) -> void: pass
	func has_headroom(_rise: float, _from_offset := Vector3.ZERO) -> bool: return true
	func can_move(_motion: Vector3, _from_offset := Vector3.ZERO) -> bool: return false
	func force_sync_physics() -> void: synced += 1


func test_unstick_offset_is_applied_as_a_teleport() -> void:
	var body := TeleportBody.new()
	var state := Movement.MovementState.new()
	state.bind_body(body)
	state.unstick_offset = Vector3(0.0, 0.003, 0.0)
	var sim := Movement.Simulation.new(preload("res://addons/pmove/movement_config.gd").new())
	var cmd := preload("res://addons/pmove/input_command.gd").new()
	cmd.delta = 1.0 / 60.0
	sim.simulate_tick(body, state, cmd)
	assert_almost_eq(body.global_position.y, 0.003, 0.0001,
		"the offset must land on the transform, not be swept — a sweep out of a pinned pose "
		+ "goes nowhere, which is the whole reason this field is not depenetration")
	assert_gt(body.synced, 0, "the physics server has to be told about an out-of-band move")


func test_unstick_offset_is_per_tick() -> void:
	var body := TeleportBody.new()
	var state := Movement.MovementState.new()
	state.bind_body(body)
	state.unstick_offset = Vector3(0.0, 0.003, 0.0)
	var sim := Movement.Simulation.new(preload("res://addons/pmove/movement_config.gd").new())
	var cmd := preload("res://addons/pmove/input_command.gd").new()
	cmd.delta = 1.0 / 60.0
	sim.simulate_tick(body, state, cmd)
	sim.simulate_tick(body, state, cmd)
	assert_almost_eq(body.global_position.y, 0.003, 0.0001,
		"consumed by the tick it was set for; a second tick must not re-apply it")
	assert_vec3_almost_eq(state.unstick_offset, Vector3.ZERO, 0.0001, "and it is cleared")


func test_modifiers_carry_the_offset_for_replay() -> void:
	var mods := Movement.MovementModifiers.new()
	mods.unstick_offset = Vector3(1, 2, 3)
	var state := Movement.MovementState.new()
	mods.apply_to(state)
	assert_vec3_almost_eq(state.unstick_offset, Vector3(1, 2, 3), 0.0001,
		"apply_to must copy it — a player's unstick is reproduced from the buffer, not re-decided")


## The stall gate both movers share.
class WatchBody:
	var free: Array[Vector3] = []
	func can_move(_motion: Vector3, from_offset := Vector3.ZERO) -> bool:
		for f in free:
			if f.distance_to(from_offset) < 0.0001:
				return true
		return false


func test_watch_says_nothing_until_the_body_has_stalled() -> void:
	var w := Movement.UnstickWatch.new()
	var body := WatchBody.new()
	var at := Vector3.ZERO
	assert_vec3_almost_eq(w.poll(body, at, 0.1, UNIT, true), Vector3.ZERO, 0.0001,
		"the first sample only seeds the anchor")
	var gave_up := false
	for _i in 10:
		assert_vec3_almost_eq(w.poll(body, at, 0.1, UNIT, true), Vector3.ZERO, 0.0001,
			"a body with no free pose anywhere reports nothing to apply")
		gave_up = gave_up or w.gave_up()
	assert_true(gave_up, "...and says so on the poll that searched, so the caller logs it once")


func test_watch_ignores_a_body_that_is_not_trying_to_move() -> void:
	var w := Movement.UnstickWatch.new()
	var body := WatchBody.new()
	for _i in 20:
		assert_vec3_almost_eq(w.poll(body, Vector3.ZERO, 0.1, UNIT, false), Vector3.ZERO, 0.0001,
			"no intent, no symptom, no six queries every STALL_TIME")
	assert_false(w.gave_up(), "and no search ran at all")


func test_watch_frees_a_stalled_body() -> void:
	var w := Movement.UnstickWatch.new()
	var body := WatchBody.new()
	body.free = [Vector3(0.125, 0.0, 0.0) * UNIT]
	var fired := Vector3.ZERO
	for _i in 10:
		var got: Vector3 = w.poll(body, Vector3.ZERO, 0.1, UNIT, true)
		if got != Vector3.ZERO:
			fired = got
	assert_vec3_almost_eq(fired, Vector3(0.125, 0.0, 0.0) * UNIT, 0.0001,
		"stalled and pinned with an escape available = the escape")


func test_watch_backs_off_after_a_failed_search() -> void:
	var w := Movement.UnstickWatch.new()
	var body := WatchBody.new()
	for _i in 10:
		w.poll(body, Vector3.ZERO, 0.1, UNIT, true)
	# Within the retry window nothing is asked again: hand it an escape and confirm the watch
	# does not spend a search finding it until the cooldown lapses.
	body.free = [Vector3(0.125, 0.0, 0.0) * UNIT]
	assert_vec3_almost_eq(w.poll(body, Vector3.ZERO, 0.1, UNIT, true), Vector3.ZERO, 0.0001,
		"a failed search must not re-run every STALL_TIME — the geometry has not changed")
	# Past RETRY_TIME it asks again and finds it.
	var fired := Vector3.ZERO
	for _i in 60:
		var got: Vector3 = w.poll(body, Vector3.ZERO, 0.1, UNIT, true)
		if got != Vector3.ZERO:
			fired = got
	assert_vec3_almost_eq(fired, Vector3(0.125, 0.0, 0.0) * UNIT, 0.0001,
		"...but it does ask again once the cooldown lapses")
