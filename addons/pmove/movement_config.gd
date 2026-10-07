extends RefCounted
## Physics constants for one movement simulation instance.
## Construct one and pass it to ServerMovement/ClientMovement._init().
## Default values match GoldSrc/Half-Life physics scaled to Godot metres (1 unit = 1m).
## No class_name — use preload("res://addons/pmove/movement_config.gd").

# Movement
var max_speed      := 8.0       # 320 sv_units — sv_maxspeed
var stop_speed     := 2.5       # 100 sv_units — sv_stopspeed
var accelerate     := 10.0      # sv_accelerate (dimensionless)
var air_accelerate := 10.0      # sv_airaccelerate (dimensionless)
var air_speed_cap  := 0.75      # 30 sv_units — max wishspeed for air addspeed check
var friction       := 4.0       # sv_friction (dimensionless)
var gravity        := 20.0      # 800 sv_units — sv_gravity
var jump_speed     := 6.7082    # sqrt(2*gravity*1.125) — jump height ≈ 1.125m
var ladder_speed   := 5.0       # 200 sv_units — MAX_CLIMB_SPEED
var ladder_jump    := 6.75      # 270 sv_units — ladder dismount push-off speed
var max_velocity   := 50.0      # 2000 sv_units — sv_maxvelocity
var water_speed    := 5.0       # 200 sv_units — swim speed
var water_friction := 4.0       # water drag (dimensionless)
var step_height    := 0.45      # 18 sv_units — sv_stepsize
var min_step_rise  := 0.003125  # ~3mm — minimum vertical rise to classify as a real step

# Crouch & walk
var stand_height   := 1.8       # 72 sv_units — standing hull height
var crouch_height  := 0.9       # 36 sv_units — crouched hull height
var stand_eye      := 1.6       # 64 sv_units — standing eye from floor
var crouch_eye     := 0.75      # 30 sv_units — crouched eye from floor
var duck_mult      := 0.333     # PLAYER_DUCKING_MULTIPLIER
var walk_mult      := 0.5       # +speed halves maxspeed
var duck_time      := 0.4       # TIME_TO_DUCK (seconds)
