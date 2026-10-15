class_name PmoveCharacter3D extends CharacterBody3D
## GoldSrc movement as a node: add it, give it a CollisionShape3D, and it walks, steps, jumps,
## crouches, climbs ladders and swims the way Half-Life does.
##
## Turn it by setting its rotation.y and aim with [member pitch], which steers ladders and
## swimming. [member velocity] is the movement's own: set it for a knockback or a launch pad.
## Read [member on_floor] rather than is_on_floor(), which the step-up leaves unreliable.
##
## This is the single-player front door. Prediction, server authority and bodies that are not
## nodes drive the kernel (movement.gd) directly.

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const LadderWater = preload("res://addons/pmove/ladder_water.gd")
const GodotBodyScript = preload("res://addons/pmove/godot_body.gd")

## Left the ground under its own jump, bunny hops included.
signal jumped
## Touched down from a fall; `impact_speed` is the downward speed, in m/s, for fall damage.
signal landed(impact_speed: float)

## Shared between characters is fine: nothing here writes to it.
@export var config: MovementConfig

@export_group("Input")
## Off, and the game sets [member move_input], [member jump], [member crouch] and [member walk].
@export var read_input := true
@export var action_left: StringName = &"ui_left"
@export var action_right: StringName = &"ui_right"
@export var action_forward: StringName = &"ui_up"
@export var action_back: StringName = &"ui_down"
@export var action_jump: StringName = &"ui_accept"
@export var action_crouch: StringName = &""
@export var action_walk: StringName = &""

@export_group("Volumes")
## Area3Ds on these layers are ladders. One climbs out along the area's +Z, unless it has a
## "ladder_normal" Vector3 meta.
@export_flags_3d_physics var ladder_layers := 0
## Area3Ds on these layers are water, swum in once the waist is under.
@export_flags_3d_physics var water_layers := 0

## Look pitch in radians, negative down.
var pitch := 0.0
## x right, y back, as Input.get_vector returns it.
var move_input := Vector2.ZERO
var jump := false
var crouch := false
var walk := false

var on_floor: bool:
	get: return state.on_floor
var is_crouched: bool:
	get: return state.is_crouched
## Eye height above the feet, eased while crouching: where a first-person camera goes.
var eye_height: float:
	get: return state.eye_y
var on_ladder := false
var in_water := false

var simulation: Movement.Simulation
var state := Movement.MovementState.new()

var _body: GodotBodyScript
var _driver := LadderWater.Driver.new()
var _volume_query := PhysicsPointQueryParameters3D.new()


func _ready() -> void:
	if config == null:
		config = MovementConfig.new()
	simulation = Movement.Simulation.new(config)
	# walk_move steps by itself and the kernel judges floors by WALK_NORMAL_Y, so Godot's own
	# snap must stay off and its floor angle must agree.
	floor_snap_length = 0.0
	floor_max_angle = deg_to_rad(46.0)
	# Crouching resizes the hull's shape, which would resize every body sharing it.
	for child in get_children():
		if child is CollisionShape3D:
			if child.shape:
				child.shape = child.shape.duplicate()
			break
	_body = GodotBodyScript.new(self)
	state.bind_body(_body)
	state._stand_height = config.stand_height
	state._crouch_height = config.crouch_height
	state.eye_y = config.stand_eye
	state.is_crouched = false
	_volume_query.collide_with_areas = true
	_volume_query.collide_with_bodies = false


func _physics_process(delta: float) -> void:
	if read_input:
		_read_input()
	var cmd := InputCommand.new()
	cmd.move_input = move_input
	cmd.jump = jump
	cmd.crouch = crouch
	cmd.walk = walk
	cmd.yaw = rotation.y
	cmd.pitch = pitch
	cmd.delta = delta

	var ladder := _volume_at_waist(ladder_layers)
	on_ladder = ladder != null
	in_water = _volume_at_waist(water_layers) != null
	var ladder_normal := Vector3.ZERO
	if on_ladder:
		ladder_normal = ladder.get_meta(&"ladder_normal", ladder.global_basis.z.normalized())
	var mods := Movement.MovementModifiers.new()
	_driver.apply(mods, config, state, cmd, on_ladder, ladder_normal, in_water,
			get_world_3d().direct_space_state)
	mods.apply_to(state)

	# After a tick the two agree, so a difference is the game's own write.
	state.velocity = velocity
	var was_on_floor := state.on_floor
	simulation.simulate_tick(_body, state, cmd)

	if was_on_floor and state.is_jumping and not state.velocity_override_active:
		jumped.emit()
	if state.landing_impact_speed > 0.0:
		landed.emit(state.landing_impact_speed)


func _read_input() -> void:
	move_input = Vector2(_strength(action_right) - _strength(action_left),
			_strength(action_back) - _strength(action_forward)).limit_length(1.0)
	jump = _pressed(action_jump)
	crouch = _pressed(action_crouch)
	walk = _pressed(action_walk)


func _pressed(action: StringName) -> bool:
	return not action.is_empty() and InputMap.has_action(action) and Input.is_action_pressed(action)


func _strength(action: StringName) -> float:
	if action.is_empty() or not InputMap.has_action(action):
		return 0.0
	return Input.get_action_strength(action)


## The first volume on `layers` at the waist, GoldSrc's waterlevel 2, or null.
func _volume_at_waist(layers: int) -> Area3D:
	if layers == 0:
		return null
	_volume_query.position = global_position + Vector3(0, config.stand_height * 0.5, 0)
	_volume_query.collision_mask = layers
	var hits := get_world_3d().direct_space_state.intersect_point(_volume_query, 1)
	return hits[0].collider if not hits.is_empty() else null
