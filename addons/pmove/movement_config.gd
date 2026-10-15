class_name PmoveConfig extends Resource
## Physics constants for one movement simulation instance.
## Construct one and pass it to ServerMovement/ClientMovement._init(), or save one as a .tres and
## give it to a PmoveCharacter3D.
## Default values match GoldSrc/Half-Life physics scaled to Godot metres (1 unit = 1m).
## Scripts load it by path (preload("res://addons/pmove/movement_config.gd")); the class name is
## for the inspector, and is prefixed so it can't collide with a game's own MovementConfig.

@export_group("Movement")
@export var max_speed      := 8.0       # 320 sv_units — sv_maxspeed
@export var stop_speed     := 2.5       # 100 sv_units — sv_stopspeed
@export var accelerate     := 10.0      # sv_accelerate (dimensionless)
@export var air_accelerate := 10.0      # sv_airaccelerate (dimensionless)
@export var air_speed_cap  := 0.75      # 30 sv_units — max wishspeed for air addspeed check
@export var friction       := 4.0       # sv_friction (dimensionless)
@export var gravity        := 20.0      # 800 sv_units — sv_gravity
@export var jump_speed     := 6.7082    # sqrt(2*gravity*1.125) — jump height ≈ 1.125m
@export var ladder_speed   := 5.0       # 200 sv_units — MAX_CLIMB_SPEED
@export var ladder_jump    := 6.75      # 270 sv_units — ladder dismount push-off speed
@export var max_velocity   := 50.0      # 2000 sv_units — sv_maxvelocity
@export var water_speed    := 5.0       # 200 sv_units — swim speed
@export var water_friction := 4.0       # water drag (dimensionless)
@export var step_height    := 0.45      # 18 sv_units — sv_stepsize
@export var min_step_rise  := 0.003125  # ~3mm — minimum vertical rise to classify as a real step

@export_group("Crouch & walk")
@export var stand_height   := 1.8       # 72 sv_units — standing hull height
@export var crouch_height  := 0.9       # 36 sv_units — crouched hull height
@export var stand_eye      := 1.6       # 64 sv_units — standing eye from floor
@export var crouch_eye     := 0.75      # 30 sv_units — crouched eye from floor
@export var duck_mult      := 0.333     # PLAYER_DUCKING_MULTIPLIER
@export var walk_mult      := 0.5       # +speed halves maxspeed
@export var duck_time      := 0.4       # TIME_TO_DUCK (seconds)
