extends "res://tests/suite.gd"
## A capsule steps up stairs it can walk up — and still not up a slope it can't stand on.
##
## The step path accepts a landing by its contact normal. A box lands flat on a stair top; a
## capsule lands on the stair's edge, where the normal points at its centre, and from rest
## against a 0.4 m riser that read ~0.3: the capsule stopped dead at the first step and never
## climbed it. Real bodies here, because the contact normal is the physics server's answer.

const Movement = preload("res://addons/pmove/movement.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")

const RISER := 0.4
const TREAD := 1.2


func _slab(size: Vector3, pos: Vector3, rot_z := 0.0) -> void:
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	sb.add_child(cs)
	sb.position = pos
	sb.rotation.z = rot_z
	_root().add_child(_keep(sb))


## Walks a capsule player toward -z for `ticks`; returns the highest it got.
func _walk(ticks: int, start := Vector3.ZERO, move := Vector2(0, -1)) -> float:
	var player := CharacterBody3D.new()
	player.floor_max_angle = deg_to_rad(46.0)
	player.floor_snap_length = 0.0
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	player.add_child(cs)
	_root().add_child(_keep(player))
	player.global_position = start

	var sim := Movement.Simulation.new(MovementConfig.new())
	var body := GodotBody.new(player)
	var state := Movement.MovementState.new()
	state.on_floor = true
	var top := 0.0
	for i in ticks:
		var cmd := InputCommand.new()
		cmd.move_input = move
		cmd.delta = 1.0 / 60.0
		sim.simulate_tick(body, state, cmd)
		top = maxf(top, player.global_position.y)
	return top


func test_capsule_climbs_stairs_from_rest() -> void:
	_slab(Vector3(20, 1, 20), Vector3(0, -0.5, 0))
	for i in 3:
		_slab(Vector3(3, RISER, TREAD), Vector3(0, RISER * 0.5 + i * RISER, -1.0 - TREAD * 0.5 - i * TREAD))
	# Starts touching the first riser: no run-up, so no tick ever overhangs the edge far enough
	# for the contact normal alone to pass.
	var top := _walk(90, Vector3(0, 0, -0.6))
	assert_almost_eq(top, RISER * 3, 0.02, "the capsule should reach the third step's top")


func test_capsule_still_refuses_a_slope_it_cannot_stand_on() -> void:
	# The control: past the contact on a 59-degree face is the same face, so the step path must
	# keep refusing it (ww_2fort's lift ropes, normal.y 0.51).
	_slab(Vector3(20, 1, 20), Vector3(0, -0.5, 0))
	var t := acos(0.51)
	_slab(Vector3(8, 1, 3), Vector3(-sin(t), cos(t), 0) * -0.5, t)
	var top := _walk(90, Vector3(-3.0, 0.0, 0), Vector2(1, 0))
	assert_lt(top, 0.6, "a capsule must not step its way up a slope steeper than it can stand on")
