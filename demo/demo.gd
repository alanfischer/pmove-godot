extends Node3D
## A course for feeling the movement: flat ground to build speed on, stairs to walk up without
## catching, a ramp to surf down, a gap that needs a bunny-hopped landing, a doorframe, a ladder
## and a pool to climb out of — the geometry GoldSrc movement exists to handle gracefully and
## `move_and_slide` does not.
##
## Everything is built in code so the scene file stays a single node and the course is readable
## as geometry rather than as a .tscn diff. Keys are read directly rather than through an input
## map so the demo needs no project setup.
##
## WASD move · Space jump (re-press on landing to bunny-hop; swim up; push off a ladder) ·
## Ctrl crouch (sink) · Shift walk · B switch box/capsule hull · Esc release mouse

const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")
const InputCommand = preload("res://addons/pmove/input_command.gd")
const LadderWater = preload("res://addons/pmove/ladder_water.gd")

const MOUSE_SENS := 0.0022
const LAYER_WATER := 2
const LAYER_LADDER := 4
# GoldSrc's waterlevel 2: deep enough to swim once the waist is under.
const WAIST := 0.9

var _cfg := MovementConfig.new()
var _sim: Movement.Simulation
var _state: Movement.MovementState
var _body: GodotBody
var _hull_shape: CollisionShape3D
var _hull_mesh: MeshInstance3D
var _use_capsule: bool = true
var _char: CharacterBody3D
var _camera: Camera3D
var _readout: Label
var _driver := LadderWater.Driver.new()
var _volume_query := PhysicsPointQueryParameters3D.new()
var _on_ladder := false
var _in_water := false

var _yaw := 0.0
var _pitch := 0.0
var _top_speed := 0.0


func _ready() -> void:
	_sim = Movement.Simulation.new(_cfg)
	_state = Movement.MovementState.new()
	_build_world()
	_build_player()
	_build_hud()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# --- the course ---

func _build_world() -> void:
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(35.0), 0.0)
	light.shadow_enabled = true
	add_child(light)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# Ground, around a 6 x 8 m hole for the pool.
	_box(Vector3(9, 1, 60), Vector3(-25.5, -0.5, 0))
	_box(Vector3(45, 1, 60), Vector3(7.5, -0.5, 0))
	_box(Vector3(6, 1, 40), Vector3(-18, -0.5, -10))
	_box(Vector3(6, 1, 12), Vector3(-18, -0.5, 24))

	# Stairs. 0.4 m risers are taller than most controllers will step and inside GoldSrc's
	# 18-unit sv_stepsize, so walking up these without catching is the whole point of walk_move.
	for i in 8:
		_box(Vector3(3, 0.4, 1.2), Vector3(-9, 0.2 + i * 0.4, -4 - i * 1.2))

	# A 30-degree ramp to run down and surf along.
	var ramp := _box(Vector3(6, 0.4, 14), Vector3(9, 2.0, -6))
	ramp.rotation.x = deg_to_rad(-20.0)

	# A gap. Clearing it needs speed kept across a landing, which is what bunny-hopping is.
	_box(Vector3(5, 1, 6), Vector3(0, -0.5, -14))
	_box(Vector3(5, 1, 6), Vector3(0, -0.5, -26))

	# A doorframe: the classic case where a naive slide catches on the jamb.
	_box(Vector3(0.4, 3, 4), Vector3(-2.2, 1.5, 6))
	_box(Vector3(0.4, 3, 4), Vector3(2.2, 1.5, 6))
	_box(Vector3(4.8, 0.6, 4), Vector3(0, 3.3, 6))

	# A low lip to crouch under.
	_box(Vector3(6, 0.4, 0.6), Vector3(16, 1.0, 4))

	# A pool. Its surface is 0.3 m under the ground, so a swimmer at the bank climbs out with a
	# water-jump, and its floor is deep enough to dive to.
	_box(Vector3(6, 1, 8), Vector3(-18, -3.0, 14))
	_box(Vector3(0.5, 2.5, 8), Vector3(-21.25, -1.25, 14))
	_box(Vector3(0.5, 2.5, 8), Vector3(-14.75, -1.25, 14))
	_box(Vector3(7, 2.5, 0.5), Vector3(-18, -1.25, 9.75))
	_box(Vector3(7, 2.5, 0.5), Vector3(-18, -1.25, 18.25))
	_volume(Vector3(6, 2.2, 8), Vector3(-18, -1.4, 14), LAYER_WATER, Color(0.2, 0.45, 0.9, 0.45))

	# A tower with a ladder up its south face. The ladder runs past the top so a climber's waist
	# clears the roof before it lets go, and they walk off onto it.
	_box(Vector3(3, 5, 3), Vector3(12, 2.5, 16))
	var ladder := _volume(Vector3(1.2, 6.5, 0.8), Vector3(12, 3.25, 17.9), LAYER_LADDER,
			Color(0.55, 0.35, 0.15, 0.6))
	ladder.set_meta("normal", Vector3(0, 0, 1))


func _box(size: Vector3, pos: Vector3) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.position = pos
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	sb.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	var mat := StandardMaterial3D.new()
	# Tint by height so the course reads at a glance without textures.
	mat.albedo_color = Color.from_hsv(0.55, 0.12, clampf(0.45 + pos.y * 0.06, 0.2, 0.9))
	mesh.material_override = mat
	sb.add_child(mesh)
	add_child(sb)
	return sb


## A volume the player is in or out of — water or a ladder — found with a point query.
func _volume(size: Vector3, pos: Vector3, layer: int, tint: Color) -> Area3D:
	var area := Area3D.new()
	area.position = pos
	area.collision_layer = layer
	area.collision_mask = 0
	area.monitoring = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	area.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material_override = mat
	area.add_child(mesh)
	add_child(area)
	return area


## The first volume on `layer` at the player's waist, or null.
func _volume_at_waist(layer: int) -> Area3D:
	_volume_query.position = _state.position + Vector3(0, WAIST, 0)
	_volume_query.collide_with_areas = true
	_volume_query.collide_with_bodies = false
	_volume_query.collision_mask = layer
	var hits := get_world_3d().direct_space_state.intersect_point(_volume_query, 1)
	return hits[0].collider if not hits.is_empty() else null


# --- the player ---

func _build_player() -> void:
	_char = CharacterBody3D.new()
	_char.position = Vector3(0, 2, 10)
	# GoldSrc treats anything up to ~45 degrees as standable; the kernel's WALK_NORMAL_Y agrees.
	_char.floor_max_angle = deg_to_rad(46.0)
	# walk_move does its own stepping, and the kernel owns rider carry, so Godot's helpers for
	# both stay off — two systems solving the same problem fight each other.
	_char.floor_snap_length = 0.0
	_char.platform_floor_layers = 0

	_hull_shape = CollisionShape3D.new()
	_hull_shape.position.y = _cfg.stand_height * 0.5
	_char.add_child(_hull_shape)
	_set_hull(_cfg.stand_height)

	_hull_mesh = MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.35, 0.25)
	_hull_mesh.material_override = mat
	_char.add_child(_hull_mesh)

	_camera = Camera3D.new()
	add_child(_camera)

	add_child(_char)
	_body = GodotBody.new(_char)
	_state.bind_body(_body)


## A fresh shape of the chosen kind at `height`. The centre is left alone: crouching in the
## air raises it, and a switch mid-crouch must keep that.
func _set_hull(height: float) -> void:
	if _use_capsule:
		var cap := CapsuleShape3D.new()
		cap.radius = 0.4
		cap.height = height
		_hull_shape.shape = cap
	else:
		var box := BoxShape3D.new()
		box.size = Vector3(0.8, height, 0.8)
		_hull_shape.shape = box


func _toggle_hull() -> void:
	var height := GodotBody.height_of(_hull_shape.shape)
	_use_capsule = not _use_capsule
	_set_hull(height)


## The visible hull follows the collision one, which crouching resizes under us.
func _sync_hull_mesh() -> void:
	var s = _hull_shape.shape
	var m = _hull_mesh.mesh
	if s is BoxShape3D:
		if not m is BoxMesh:
			m = BoxMesh.new()
			_hull_mesh.mesh = m
		m.size = s.size
	else:
		if not m is CapsuleMesh:
			m = CapsuleMesh.new()
			_hull_mesh.mesh = m
		m.radius = s.radius
		m.height = s.height
	_hull_mesh.position = _hull_shape.position


func _build_hud() -> void:
	_readout = Label.new()
	_readout.position = Vector2(16, 12)
	_readout.add_theme_font_size_override("font_size", 16)
	_readout.add_theme_color_override("font_color", Color.WHITE)
	_readout.add_theme_color_override("font_outline_color", Color.BLACK)
	_readout.add_theme_constant_override("outline_size", 6)
	var layer := CanvasLayer.new()
	layer.add_child(_readout)
	add_child(layer)


# --- input ---

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * MOUSE_SENS
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENS, -PI / 2.0, PI / 2.0)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif event is InputEventMouseButton and event.pressed:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_B:
		_toggle_hull()


func _physics_process(delta: float) -> void:
	var cmd := InputCommand.new()
	cmd.move_input = Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	cmd.jump = Input.is_physical_key_pressed(KEY_SPACE)
	cmd.crouch = Input.is_physical_key_pressed(KEY_CTRL)
	cmd.walk = Input.is_physical_key_pressed(KEY_SHIFT)
	cmd.yaw = _yaw
	cmd.pitch = _pitch
	cmd.delta = delta

	# The game's half of ladders and water: say where they are. The driver picks the move.
	var ladder := _volume_at_waist(LAYER_LADDER)
	_on_ladder = ladder != null
	_in_water = _volume_at_waist(LAYER_WATER) != null
	var mods := Movement.MovementModifiers.new()
	_driver.apply(mods, _cfg, _state, cmd, _on_ladder,
			ladder.get_meta("normal") if _on_ladder else Vector3.ZERO, _in_water,
			get_world_3d().direct_space_state)
	mods.apply_to(_state)
	_sim.simulate_tick(_body, _state, cmd)

	_sync_hull_mesh()

	# Third-person camera: orbit behind the player and always frame its centre, so
	# tilting the view never loses the capsule.
	var pivot := _hull_shape.global_position
	var offset := Basis(Vector3.UP, _yaw) * Vector3(0.0, 4.0 + _pitch * 2.0, 6.0)
	_camera.global_position = pivot + offset
	_camera.look_at(pivot, Vector3.UP)

	if _char.position.y < -20.0:
		_char.position = Vector3(0, 2, 10)
		_char.velocity = Vector3.ZERO
		_driver.reset()
		_top_speed = 0.0

	var speed := Vector2(_state.velocity.x, _state.velocity.z).length()
	_top_speed = maxf(_top_speed, speed)
	# Shown in GoldSrc units too (40 u = 1 m), since that is the vocabulary the numbers that
	# tune this are written in: sv_maxspeed 320 is the 8 m/s ground cap.
	_readout.text = "%.1f m/s  (%d u/s)   top %.1f m/s\n%s%s\nHull: %s  (press B to switch)" % [
		speed, roundi(speed * 40.0), _top_speed,
		"ladder" if _on_ladder else "swimming" if _in_water \
				else "ground" if _state.on_floor else "air",
		"  crouched" if _state.is_crouched else "",
		"capsule" if _use_capsule else "box"]
